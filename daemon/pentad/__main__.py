"""pentad — the PENTA system daemon.

    sudo python3 -m pentad              # on the console
    python3 -m pentad --mock            # on the Mac, for menu development

Everything privileged lives here. The menu is a client with no special rights,
which is why it can crash, restart, or be rewritten without the console caring.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys

from .dualsense import ControllerService
from .inputs import InputWatcher
from .power import PowerManager
from .server import Server
from .session import SessionManager
from .storage import StorageService
from .titles import (Library, MockProvider, NativeProvider, RomProvider,
                     SteamProvider, SystemProvider)

log = logging.getLogger("pentad")

BATTERY_POLL_S = 30.0


def build_library(mock: bool) -> Library:
    if mock:
        return Library([MockProvider()])
    return Library([SteamProvider(), NativeProvider(), RomProvider(),
                    SystemProvider()])


async def run(mock: bool) -> None:
    server = Server()
    emit = server.emit

    library = build_library(mock)

    # Playtime is only known once a title exits, so the library is updated from
    # the event on its way out rather than guessed at launch.
    def emit_tracked(event: str, **args) -> None:
        if event == "title.exited":
            library.touch(args.get("uid", ""), int(args.get("played_s", 0)))
        emit(event, **args)

    session = SessionManager(emit_tracked, mock=mock)
    power = PowerManager(emit, mock=mock)
    controllers = ControllerService(emit, mock=mock)
    storage = StorageService(mock=mock)
    inputs = InputWatcher(emit, mock=mock)

    library.refresh()
    controllers.refresh()

    # --- Commands -------------------------------------------------------------

    @server.command("ping")
    async def _ping(_args):
        return {"pong": True, "mock": mock, "commands": server.commands}

    @server.command("library.list")
    async def _library_list(_args):
        return {"titles": [t.to_json() for t in library.sorted()]}

    @server.command("library.refresh")
    async def _library_refresh(_args):
        titles = library.refresh()
        emit("library.changed", count=len(titles))
        return {"titles": [t.to_json() for t in titles]}

    @server.command("title.launch")
    async def _title_launch(args):
        title = library.get(args["uid"])
        await session.launch(title.uid, title.launch)
        return {"ok": True}

    @server.command("title.close")
    async def _title_close(_args):
        await session.close()
        return {"ok": True}

    @server.command("system.status")
    async def _status(_args):
        return {
            "running_uid": session.running_uid,
            "controllers": controllers.status(),
            "storage": storage.usage(),
            "mock": mock,
        }

    @server.command("led.set")
    async def _led(args):
        controllers.set_lightbar(int(args.get("r", 0)),
                                 int(args.get("g", 0)),
                                 int(args.get("b", 0)))
        return {"ok": True}

    @server.command("controller.rescan")
    async def _rescan(_args):
        controllers.refresh()
        await inputs.rescan()
        return controllers.status()

    @server.command("system.selftest")
    async def _selftest(_args):
        """First-boot hardware probe results, written by penta-selftest."""
        import json as _json
        import pathlib as _pathlib
        path = _pathlib.Path("/var/lib/penta/selftest.json")
        if mock:
            return {"pass": 9, "fail": 1, "checks": {"nvidia_smi": True,
                    "bluetooth": True, "data_partition": False}}
        if not path.exists():
            return {"ran": False}
        try:
            return {"ran": True, **_json.loads(path.read_text())}
        except (OSError, ValueError) as exc:
            raise RuntimeError(f"unreadable selftest results: {exc}") from exc

    @server.command("steam.store")
    async def _steam_store(args):
        """Open a store page in Steam. The store screen browses the catalogue in
        our own UI, but buying stays in Steam — payments and account handling
        are not something to reimplement."""
        # Godot parses JSON numbers as floats, so an appid arrives as
        # "1675200.0". Normalise rather than rejecting it.
        raw = str(args.get("appid", "")).strip()
        try:
            appid = str(int(float(raw)))
        except ValueError:
            raise ValueError(f"bad appid {raw!r}") from None
        url = f"steam://store/{appid}"
        if mock:
            log.info("[mock] would open %s", url)
            return {"ok": True, "url": url, "mock": True}
        import shutil as _shutil
        import sys as _sys
        if _shutil.which("steam"):
            argv = ["steam", url]
        elif _sys.platform == "darwin":
            argv = ["open", url]          # macOS resolves steam:// itself
        else:
            raise RuntimeError("Steam is not installed")
        await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL)
        return {"ok": True, "url": url}

    @server.command("steam.status")
    async def _steam_status(_args):
        """Where Steam is and how many games it has.

        'Installed but empty' and 'not installed' look identical in an empty
        library, so the UI needs to be able to tell them apart."""
        if mock:
            return {"installed": True, "games": 10, "libraries": ["(mock)"],
                    "roots": ["(mock)"]}
        return SteamProvider.status()

    @server.command("storage.usage")
    async def _storage(_args):
        return storage.usage()

    server.register("power.rest", lambda a: power.rest())
    server.register("power.restart", lambda a: power.restart())
    server.register("power.off", lambda a: power.off())

    # --- Background work ------------------------------------------------------

    async def hardware_loop():
        """Battery + controller presence.

        Polled rather than driven by udev: a udev rule firing systemctl on
        every input event is a lot of machinery for something a 30s tick
        handles, and it keeps the daemon's dependencies to evdev alone.
        """
        known = controllers.status().get("count", 0)
        while True:
            await asyncio.sleep(BATTERY_POLL_S)
            try:
                controllers.poll_battery()
                count = controllers.status().get("count", 0)
                if count != known:
                    known = count
                    controllers.refresh()
                    await inputs.rescan()
                    emit("controller.changed", count=count)
            except Exception as exc:                       # noqa: BLE001
                log.warning("hardware poll failed: %s", exc)

    await inputs.start()
    asyncio.create_task(hardware_loop())

    log.info("pentad ready (%s) — %d commands",
             "mock" if mock else "live", len(server.commands))
    await server.serve()


def main() -> int:
    ap = argparse.ArgumentParser(prog="pentad")
    ap.add_argument("--mock", action="store_true",
                    help="fake hardware and library; runs on macOS")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)-18s %(message)s",
        datefmt="%H:%M:%S")

    try:
        asyncio.run(run(args.mock))
    except KeyboardInterrupt:
        log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
