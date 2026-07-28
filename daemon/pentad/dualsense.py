"""DualSense extras over raw HID.

The kernel's `hid-playstation` driver gives us buttons, sticks, touchpad, gyro,
rumble and battery through normal evdev/sysfs. It does **not** expose the
lightbar colour or the adaptive triggers — those need raw HID output reports,
and nothing else will do.

Report layout differs between USB and Bluetooth: USB uses report 0x02 with a
47-byte payload; Bluetooth uses 0x31 with a leading sequence byte and a
trailing CRC32 over the whole frame. Getting the CRC wrong means the controller
silently ignores you, which is a fun afternoon.
"""

from __future__ import annotations

import glob
import logging
import os
import zlib
from typing import List, Optional

log = logging.getLogger("pentad.dualsense")

VENDOR_SONY = 0x054C
PRODUCT_DUALSENSE = 0x0CE6

# Feature flags in the output report (bytes 0-1 of the common payload).
FLAG0_RUMBLE = 0x01 | 0x02
FLAG1_LIGHTBAR = 0x04
FLAG1_PLAYER_LED = 0x10
FLAG1_RELEASE_LEDS = 0x08

# Bluetooth frames are CRC'd with this seed byte prepended.
BT_CRC_SEED = bytes([0xA2])


class DualSense:
    """One connected controller, addressed through its hidraw node."""

    def __init__(self, path: str, bluetooth: bool) -> None:
        self.path = path
        self.bluetooth = bluetooth
        self._fd: Optional[int] = None
        self._seq = 0

    # --- Discovery ------------------------------------------------------------

    @staticmethod
    def discover() -> List["DualSense"]:
        found: List[DualSense] = []
        for dev in glob.glob("/sys/class/hidraw/hidraw*"):
            try:
                uevent = open(os.path.join(dev, "device", "uevent")).read()
            except OSError:
                continue
            if f"{VENDOR_SONY:04X}:{PRODUCT_DUALSENSE:04X}" not in uevent.upper():
                continue
            # HID_NAME/BUS tells us the transport; BT frames need the CRC path.
            bluetooth = "BLUETOOTH" in uevent.upper()
            node = "/dev/" + os.path.basename(dev)
            found.append(DualSense(node, bluetooth))
        log.info("found %d DualSense controller(s)", len(found))
        return found

    # --- Transport ------------------------------------------------------------

    def _open(self) -> int:
        if self._fd is None:
            self._fd = os.open(self.path, os.O_RDWR | os.O_NONBLOCK)
        return self._fd

    def close(self) -> None:
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    def _send(self, payload: bytes) -> None:
        """Frame a 47-byte common payload for the active transport and write it."""
        if self.bluetooth:
            self._seq = (self._seq + 1) & 0x0F
            frame = bytes([0x31, self._seq << 4]) + payload
            crc = zlib.crc32(BT_CRC_SEED + frame) & 0xFFFFFFFF
            frame += crc.to_bytes(4, "little")
        else:
            frame = bytes([0x02]) + payload

        try:
            os.write(self._open(), frame)
        except OSError as exc:
            # A controller that walked out of range must not raise into the
            # menu's request path — the lightbar is decoration.
            log.debug("write to %s failed: %s", self.path, exc)
            self.close()

    # --- Effects --------------------------------------------------------------

    def set_lightbar(self, r: int, g: int, b: int) -> None:
        payload = bytearray(47)
        payload[0] = 0x00
        payload[1] = FLAG1_LIGHTBAR | FLAG1_RELEASE_LEDS
        payload[44] = max(0, min(255, r))
        payload[45] = max(0, min(255, g))
        payload[46] = max(0, min(255, b))
        self._send(bytes(payload))

    def set_player_led(self, index: int) -> None:
        """Player indicator, 1-4. The five LEDs are a bar, not a number."""
        patterns = {1: 0x04, 2: 0x0A, 3: 0x15, 4: 0x1B}
        payload = bytearray(47)
        payload[1] = FLAG1_PLAYER_LED
        payload[43] = patterns.get(index, 0x04)
        self._send(bytes(payload))

    def battery(self) -> Optional[dict]:
        for base in glob.glob("/sys/class/power_supply/ps-controller-battery-*"):
            try:
                pct = int(open(os.path.join(base, "capacity")).read().strip())
                status = open(os.path.join(base, "status")).read().strip()
                return {"pct": pct, "charging": status.lower() == "charging"}
            except (OSError, ValueError):
                continue
        return None


class ControllerService:
    """Keeps the set of connected controllers and applies effects to all of them."""

    def __init__(self, emit, mock: bool = False) -> None:
        self._emit = emit
        self._mock = mock
        self._devices: List[DualSense] = []
        self._last_pct: Optional[int] = None

    def refresh(self) -> None:
        if self._mock:
            return
        for d in self._devices:
            d.close()
        self._devices = DualSense.discover()
        for i, d in enumerate(self._devices, start=1):
            d.set_player_led(i)

    def set_lightbar(self, r: int, g: int, b: int) -> None:
        if self._mock:
            log.debug("[mock] lightbar %d,%d,%d", r, g, b)
            return
        for d in self._devices:
            d.set_lightbar(r, g, b)

    def status(self) -> dict:
        if self._mock:
            return {"count": 1, "battery": {"pct": 78, "charging": False}}
        battery = self._devices[0].battery() if self._devices else None
        return {"count": len(self._devices), "battery": battery}

    def poll_battery(self) -> None:
        """Emit only on change — a battery event every 30s is noise."""
        st = self.status().get("battery")
        if not st:
            return
        pct = st["pct"]
        if pct != self._last_pct:
            self._last_pct = pct
            self._emit("controller.battery", **st)
