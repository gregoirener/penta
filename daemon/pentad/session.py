"""Running a title.

Games run *inside* gamescope, one at a time. That's what gives resolution
decoupling, frame limiting and a tear-free handoff — and it means there is
never a moment where the desktop is visible, because there is no desktop.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import time
from typing import List, Optional

log = logging.getLogger("pentad.session")

# Hybrid graphics: the panel hangs off the iGPU, so games have to be explicitly
# offloaded to the Nvidia GPU. Without these a game silently runs on the iGPU
# and everyone blames the port.
PRIME_ENV = {
    "__NV_PRIME_RENDER_OFFLOAD": "1",
    "__GLX_VENDOR_LIBRARY_NAME": "nvidia",
    "__VK_LAYER_NV_optimus": "NVIDIA_only",
}


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

    async def launch(self, uid: str, argv: List[str]) -> None:
        if self._proc is not None:
            raise RuntimeError(f"{self._uid} is already running")
        if not argv:
            raise ValueError("title has no launch command")

        env = {**os.environ, **PRIME_ENV}
        cmd = self._wrap(argv)
        log.info("launching %s: %s", uid, " ".join(cmd))

        if self._mock:
            # Pretend the game runs for a few seconds so the menu's launch →
            # veil → return-to-focus cycle can be exercised on the Mac.
            cmd = ["sleep", "4"]

        try:
            self._proc = await asyncio.create_subprocess_exec(
                *cmd, env=env,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL)
        except (FileNotFoundError, PermissionError) as exc:
            raise RuntimeError(f"cannot launch {uid}: {exc}") from exc

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
        self._emit("title.exited", uid=uid, code=code, played_s=played)

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
