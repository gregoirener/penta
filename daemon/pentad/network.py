"""Wi-Fi, via NetworkManager.

A console with no network is a console with no games: Steam cannot sign in, no
cover art loads, and the store is empty. Ethernet comes up on its own, but the
machine this was built for has no cable — so this exists.

nmcli rather than the D-Bus API: it is already installed, it handles the whole
supplicant dance, and its terse output is trivial to parse. The daemon does not
need to become a network manager, only to drive one.
"""

from __future__ import annotations

import asyncio
import logging
import shutil
from typing import Dict, List

log = logging.getLogger("pentad.network")


async def _nmcli(*args: str, timeout: float = 45.0) -> tuple[int, str, str]:
    if not shutil.which("nmcli"):
        raise RuntimeError("NetworkManager is not installed")
    proc = await asyncio.create_subprocess_exec(
        "nmcli", *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise RuntimeError(f"nmcli {' '.join(args)} timed out") from None
    return (proc.returncode or 0,
            out.decode(errors="replace"),
            err.decode(errors="replace"))


class NetworkService:
    """Scan, connect, and report — nothing more."""

    def __init__(self, emit, mock: bool = False) -> None:
        self._emit = emit
        self._mock = mock

    async def status(self) -> Dict[str, object]:
        if self._mock:
            return {"connected": True, "ssid": "mock-net", "signal": 82,
                    "ip": "192.168.68.50", "wifi_available": True}

        if not shutil.which("nmcli"):
            return {"connected": False, "wifi_available": False,
                    "error": "NetworkManager not installed"}

        code, out, _ = await _nmcli("-t", "-f", "TYPE,STATE,CONNECTION",
                                    "device", "status")
        connected, ssid, kind = False, "", ""
        for line in out.splitlines():
            parts = line.split(":")
            if len(parts) >= 3 and parts[1] == "connected":
                connected, kind, ssid = True, parts[0], parts[2]
                if kind == "ethernet":
                    break            # wired wins if both are up

        ip = ""
        if connected:
            code, out, _ = await _nmcli("-t", "-f", "IP4.ADDRESS", "device", "show")
            for line in out.splitlines():
                if line.startswith("IP4.ADDRESS") and ":" in line:
                    ip = line.split(":", 1)[1].split("/")[0]
                    break

        code, out, _ = await _nmcli("-t", "-f", "TYPE", "device")
        wifi_available = any(l.strip() == "wifi" for l in out.splitlines())

        return {"connected": connected, "ssid": ssid, "kind": kind,
                "ip": ip, "wifi_available": wifi_available}

    async def scan(self) -> List[Dict[str, object]]:
        """Visible networks, strongest first, one entry per SSID."""
        if self._mock:
            return [
                {"ssid": "Livebox-8F2A", "signal": 88, "secure": True, "known": True},
                {"ssid": "FreeWifi_secure", "signal": 61, "secure": True, "known": False},
                {"ssid": "NEUF_A31C", "signal": 44, "secure": True, "known": False},
                {"ssid": "guest", "signal": 30, "secure": False, "known": False},
            ]

        # rescan forces a fresh survey; without it nmcli can hand back a stale
        # list from before the user moved rooms.
        await _nmcli("device", "wifi", "rescan", timeout=30.0)
        await asyncio.sleep(2.0)

        code, out, err = await _nmcli(
            "-t", "-f", "SSID,SIGNAL,SECURITY,IN-USE", "device", "wifi", "list")
        if code != 0:
            raise RuntimeError(err.strip() or "wifi scan failed")

        code, known_out, _ = await _nmcli("-t", "-f", "NAME", "connection", "show")
        known = {l.strip() for l in known_out.splitlines() if l.strip()}

        best: Dict[str, Dict[str, object]] = {}
        for line in out.splitlines():
            # SSIDs may contain colons, so split from the right.
            parts = line.rsplit(":", 3)
            if len(parts) != 4:
                continue
            ssid, signal, security, in_use = parts
            ssid = ssid.strip()
            if not ssid:
                continue                        # hidden network
            entry = {
                "ssid": ssid,
                "signal": int(signal) if signal.isdigit() else 0,
                "secure": bool(security.strip()),
                "known": ssid in known,
                "active": in_use.strip() == "*",
            }
            # One row per SSID: mesh networks advertise the same name from
            # several radios and a list of duplicates is just noise.
            if ssid not in best or entry["signal"] > best[ssid]["signal"]:
                best[ssid] = entry

        return sorted(best.values(), key=lambda e: -int(e["signal"]))

    async def connect(self, ssid: str, password: str = "") -> Dict[str, object]:
        if not ssid:
            raise ValueError("no network named")

        if self._mock:
            await asyncio.sleep(1.5)
            if password and len(password) < 8:
                raise RuntimeError("password too short")
            self._emit("network.changed", connected=True, ssid=ssid)
            return {"connected": True, "ssid": ssid}

        args = ["device", "wifi", "connect", ssid]
        if password:
            args += ["password", password]

        code, out, err = await _nmcli(*args, timeout=75.0)
        if code != 0:
            msg = (err or out).strip().splitlines()[-1] if (err or out).strip() else "failed"
            # nmcli's own wording is more useful than anything we would invent.
            raise RuntimeError(msg)

        st = await self.status()
        self._emit("network.changed", **st)
        return st

    async def forget(self, ssid: str) -> Dict[str, object]:
        if self._mock:
            return {"ok": True}
        code, _, err = await _nmcli("connection", "delete", ssid)
        if code != 0:
            raise RuntimeError(err.strip() or "could not forget that network")
        return {"ok": True}
