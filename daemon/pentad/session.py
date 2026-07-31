"""Running a title.

Games run *inside* gamescope, one at a time. That's what gives resolution
decoupling, frame limiting and a tear-free handoff — and it means there is
never a moment where the desktop is visible, because there is no desktop.

The awkward part is that pentad is a **root system service** and the compositor
is a **session owned by the `penta` user**. A process spawned straight out of
the daemon inherits neither: no WAYLAND_DISPLAY, no XDG_RUNTIME_DIR, no seat.
It exits immediately, the menu shows its launch veil, the veil clears, and
nothing happened — with the error swallowed because stdout and stderr went to
/dev/null. Everything in `_session_env` and `_as_console_user` exists to close
that gap.
"""

from __future__ import annotations

import asyncio
import glob
import logging
import os
import pwd
import shutil
import time
from typing import Dict, List, Optional

log = logging.getLogger("pentad.session")

# Hybrid graphics: the panel hangs off the iGPU, so games have to be explicitly
# offloaded to the Nvidia GPU. Without these a game silently runs on the iGPU
# and everyone blames the port.
PRIME_ENV = {
    "__NV_PRIME_RENDER_OFFLOAD": "1",
    "__GLX_VENDOR_LIBRARY_NAME": "nvidia",
    "__VK_LAYER_NV_optimus": "NVIDIA_only",
}

# The account greetd logs in and that owns the compositor.
CONSOLE_USER = "penta"

# Where a launched title's output goes. DEVNULL was costing us every launch
# failure — the one thing you need when a game does not start is what it said
# on the way out.
LAUNCH_LOG = "/var/log/penta/launch.log"


def console_user() -> Optional[pwd.struct_passwd]:
    try:
        return pwd.getpwnam(CONSOLE_USER)
    except KeyError:
        return None


def _session_env() -> Dict[str, str]:
    """Environment that points a child at the running console session.

    Empty on a machine where the session is not up (or on macOS), which is
    correct: there is nothing to point at.
    """
    user = console_user()
    if user is None:
        return {}

    runtime = f"/run/user/{user.pw_uid}"
    if not os.path.isdir(runtime):
        log.warning("no runtime dir at %s — is the console session running?", runtime)
        return {}

    env = {
        "XDG_RUNTIME_DIR": runtime,
        "HOME": user.pw_dir,
        "USER": user.pw_name,
        "LOGNAME": user.pw_name,
        "XDG_SESSION_TYPE": "wayland",
    }

    # The compositor's socket is named by whoever created it (wayland-0 for a
    # bare compositor, gamescope-0 when gamescope is the session). Discover it
    # rather than hardcoding, because which one exists depends on whether
    # penta-session fell through to cage.
    sockets = sorted(
        os.path.basename(p) for p in glob.glob(os.path.join(runtime, "wayland-*"))
        if not p.endswith(".lock")
    )
    if sockets:
        env["WAYLAND_DISPLAY"] = sockets[0]
    else:
        log.warning("no wayland socket in %s — the title will have no display",
                    runtime)
    return env


class SessionManager:
    def __init__(self, emit, mock: bool = False) -> None:
        self._emit = emit
        self._mock = mock
        self._proc: Optional[asyncio.subprocess.Process] = None
        self._uid: Optional[str] = None
        self._started: float = 0.0

    @property
    def running_uid(self) -> Optional[str]:
        return self._uid

    def _wrap(self, argv: List[str]) -> List[str]:
        """Wrap a launch command in gamescope, if it's available."""
        if self._mock or not shutil.which("gamescope"):
            return argv
        return [
            "gamescope",
            "-f",                 # fullscreen
            "-e",                 # Steam integration
            "--adaptive-sync",
            "--",
            *argv,
        ]

    def _as_console_user(self, argv: List[str]) -> List[str]:
        """Prefix argv so it runs as the console account, not as root.

        A game started as root writes root-owned files into the console
        account's home and then fails on the *next* launch as that user, which
        is a fantastically confusing bug to meet a week later. setpriv rather
        than runuser: no PAM session to open, and no chance of it trying to
        allocate a terminal we do not have.
        """
        user = console_user()
        if self._mock or user is None or os.geteuid() != 0:
            return argv
        if not shutil.which("setpriv"):
            log.warning("setpriv missing; launching as root")
            return argv
        return [
            "setpriv",
            f"--reuid={user.pw_uid}",
            f"--regid={user.pw_gid}",
            "--init-groups",
            "--inh-caps=-all",
            "--",
            *argv,
        ]

    async def launch(self, uid: str, argv: List[str]) -> None:
        if self._proc is not None:
            raise RuntimeError(f"{self._uid} is already running")
        if not argv:
            raise ValueError("title has no launch command")

        env = {**os.environ, **PRIME_ENV, **_session_env()}
        cmd = self._as_console_user(self._wrap(argv))
        log.info("launching %s: %s", uid, " ".join(cmd))

        if self._mock:
            # Pretend the game runs for a few seconds so the menu's launch →
            # veil → return-to-focus cycle can be exercised on the Mac.
            cmd = ["sleep", "4"]

        out = _launch_log()
        try:
            self._proc = await asyncio.create_subprocess_exec(
                *cmd, env=env,
                stdout=out or asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.STDOUT if out else asyncio.subprocess.DEVNULL)
        except (FileNotFoundError, PermissionError) as exc:
            raise RuntimeError(f"cannot launch {uid}: {exc}") from exc
        finally:
            if out is not None:
                out.close()

        self._uid = uid
        self._started = time.time()
        self._emit("title.launching", uid=uid)
        asyncio.create_task(self._reap())

    async def _reap(self) -> None:
        proc, uid = self._proc, self._uid
        if proc is None or uid is None:
            return
        code = await proc.wait()
        played = int(time.time() - self._started)
        self._proc = None
        self._uid = None
        log.info("%s exited (code %s) after %ds", uid, code, played)
        # A title that dies in under two seconds did not run, it failed. Say so
        # where someone will see it, and point at the log that has the reason.
        if code != 0 and played < 2:
            log.error("%s failed to start (exit %s) — see %s",
                      uid, code, LAUNCH_LOG)
        self._emit("title.exited", uid=uid, code=code, played_s=played)

    async def spawn_detached(self, argv: List[str]) -> None:
        """Fire-and-forget something into the console session.

        For things that are not titles and have no lifecycle we care about —
        handing a steam:// URL to an already-running Steam, for instance. Same
        user and same session environment as a launch, because a root process
        with no display fails exactly as invisibly here.
        """
        if self._mock:
            log.info("[mock] would spawn: %s", " ".join(argv))
            return
        env = {**os.environ, **_session_env()}
        cmd = self._as_console_user(argv)
        log.info("spawning %s", " ".join(cmd))
        out = _launch_log()
        try:
            await asyncio.create_subprocess_exec(
                *cmd, env=env,
                stdout=out or asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.STDOUT if out else asyncio.subprocess.DEVNULL)
        except (FileNotFoundError, PermissionError) as exc:
            raise RuntimeError(f"cannot run {argv[0]}: {exc}") from exc
        finally:
            if out is not None:
                out.close()

    async def close(self) -> None:
        """Ask the running title to quit; escalate if it ignores us."""
        if self._proc is None:
            return
        proc = self._proc
        proc.terminate()
        try:
            await asyncio.wait_for(proc.wait(), timeout=8.0)
        except asyncio.TimeoutError:
            log.warning("title ignored SIGTERM; killing")
            proc.kill()


def _launch_log():
    """Append-mode handle for launch output, or None if we cannot have one."""
    try:
        os.makedirs(os.path.dirname(LAUNCH_LOG), exist_ok=True)
        return open(LAUNCH_LOG, "ab", buffering=0)
    except OSError as exc:
        log.debug("no launch log (%s); output discarded", exc)
        return None
