"""Power states.

Rest Mode is `suspend-then-hibernate`: instant resume for the first stretch,
then a silent drop to zero power, resuming into exactly the game you left. It
is the one console behaviour PC "big picture" modes almost never implement, and
it's most of why a console feels different from a laptop.
"""

from __future__ import annotations

import asyncio
import logging
import shutil

log = logging.getLogger("pentad.power")


class PowerManager:
    def __init__(self, emit, mock: bool = False) -> None:
        self._emit = emit
        self._mock = mock

    async def _run(self, *args: str) -> None:
        if self._mock or not shutil.which("systemctl"):
            log.info("[mock] would run: %s", " ".join(args))
            return
        proc = await asyncio.create_subprocess_exec(
            "systemctl", *args,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE)
        _, err = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(err.decode(errors="replace").strip() or "systemctl failed")

    async def rest(self) -> None:
        # Give the menu a beat to fade out before the screen dies — otherwise
        # the last thing you see is a half-drawn frame.
        self._emit("power.resting")
        await asyncio.sleep(0.4)
        await self._run("suspend-then-hibernate")

    async def restart(self) -> None:
        self._emit("power.restarting")
        await asyncio.sleep(0.4)
        await self._run("reboot")

    async def off(self) -> None:
        self._emit("power.off")
        await asyncio.sleep(0.4)
        await self._run("poweroff")
