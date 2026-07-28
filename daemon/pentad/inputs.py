"""Global PS-button watcher.

This is the piece that makes PENTA a console rather than a launcher: the PS
button has to work *while a game is fullscreen and grabbing input*. The menu
can't do that — it isn't focused. So the daemon reads evdev directly, sees the
button regardless of who has focus, and tells the menu to come forward.

Short press → Control Center. Long press (>0.8s) → power menu.

Deliberately does **not** grab the device exclusively: games should still see
every other button. We only observe.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import List

log = logging.getLogger("pentad.inputs")

LONG_PRESS_S = 0.8

# BTN_MODE — the "guide"/PS button on every modern gamepad.
BTN_MODE = 0x13C
EV_KEY = 0x01


class InputWatcher:
    def __init__(self, emit, mock: bool = False) -> None:
        self._emit = emit
        self._mock = mock
        self._tasks: List[asyncio.Task] = []

    async def start(self) -> None:
        if self._mock:
            log.info("[mock] input watcher idle")
            return
        try:
            import evdev                                  # noqa: F401
        except ImportError:
            log.warning("python-evdev missing; PS button will not work globally")
            return
        await self.rescan()

    async def rescan(self) -> None:
        try:
            import evdev
        except ImportError:
            return

        for t in self._tasks:
            t.cancel()
        self._tasks = []

        for path in evdev.list_devices():
            try:
                dev = evdev.InputDevice(path)
            except OSError:
                continue
            caps = dev.capabilities().get(EV_KEY, [])
            if BTN_MODE in caps:
                log.info("watching PS button on %s (%s)", dev.path, dev.name)
                self._tasks.append(asyncio.create_task(self._watch(dev)))

        if not self._tasks:
            log.info("no gamepad with a PS button found yet")

    async def _watch(self, dev) -> None:
        import evdev

        pressed_at = 0.0
        try:
            async for event in dev.async_read_loop():
                if event.type != EV_KEY or event.code != BTN_MODE:
                    continue
                if event.value == 1:                      # down
                    pressed_at = time.monotonic()
                elif event.value == 0 and pressed_at:     # up
                    held = time.monotonic() - pressed_at
                    pressed_at = 0.0
                    kind = "long" if held >= LONG_PRESS_S else "short"
                    log.info("PS button: %s (%.2fs)", kind, held)
                    self._emit("input.ps_button", kind=kind)
        except (OSError, asyncio.CancelledError):
            log.info("stopped watching %s", getattr(dev, "path", "?"))

    def stop(self) -> None:
        for t in self._tasks:
            t.cancel()
        self._tasks = []
