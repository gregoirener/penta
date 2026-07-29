"""Install PENTA to an internal disk, from a PENTA running off USB.

The live USB is not a separate installer image — it is the console itself.
Installing is therefore cloning the boot device onto the target and repairing
the partition table, rather than unpacking an image we would otherwise have to
carry a second copy of.

That has three consequences worth stating:

* What you install is byte-identical to what you just booted and tried. There
  is no "the installer built it differently" class of bug.
* No compressed payload rides along, so the USB only needs to hold the console.
* systemd-repart grows the data partition to fill the target on first boot, so
  cloning a 16 GB stick onto a 1 TB NVMe is not a waste of the drive.

Everything here is destructive, so the module refuses far more than it accepts:
never the running device, never a device that isn't a whole disk, never without
an explicit confirmation token that names the target.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional

log = logging.getLogger("pentad.installer")

# Below this and it cannot hold the console.
MIN_TARGET_BYTES = 20 * 1024 ** 3

# The discoverable-partitions GUID for an EFI System Partition.
ESP_TYPE_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

# Mock topology, so the confirmation guards can be exercised on a machine that
# has neither lsblk nor a disk worth destroying. The guards are the part most
# worth testing and the part hardest to test safely.
MOCK_BOOT = "/dev/sda"
MOCK_TARGETS = [
    {"device": "/dev/nvme0n1", "size": 512 * 1024 ** 3,
     "model": "SAMSUNG MZVLB512", "rm": False},
    {"device": MOCK_BOOT, "size": 16 * 1024 ** 3,
     "model": "Flash Disk", "rm": True},
]


def _mock_targets() -> List["Target"]:
    out = []
    for m in MOCK_TARGETS:
        is_boot = m["device"] == MOCK_BOOT
        eligible, reason = True, ""
        if is_boot:
            eligible, reason = False, "this is the device PENTA is running from"
        elif m["size"] < MIN_TARGET_BYTES:
            eligible, reason = False, "too small (needs 20 GB or more)"
        out.append(Target(device=m["device"], size_bytes=m["size"],
                          model=m["model"], removable=m["rm"],
                          is_boot=is_boot, eligible=eligible, reason=reason))
    return out


@dataclass
class Target:
    device: str          # /dev/nvme0n1
    size_bytes: int
    model: str
    removable: bool
    is_boot: bool        # the device we are running from
    eligible: bool
    reason: str = ""

    def to_json(self) -> dict:
        d = asdict(self)
        d["size_gb"] = round(self.size_bytes / 1024 ** 3, 1)
        return d


async def _run(*args: str) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    return proc.returncode or 0, out.decode(errors="replace"), err.decode(errors="replace")


async def boot_disk() -> Optional[str]:
    """The whole disk the running system booted from, e.g. /dev/sda."""
    code, out, _ = await _run("findmnt", "-n", "-o", "SOURCE", "/")
    if code != 0 or not out.strip():
        return None
    part = out.strip().split("[")[0]           # strip btrfs subvol suffix
    code, out, _ = await _run("lsblk", "-no", "PKNAME", part)
    if code != 0 or not out.strip():
        return None
    return "/dev/" + out.strip().splitlines()[0]


async def list_targets() -> List[Target]:
    """Every whole disk on the machine, with a verdict on each."""
    code, out, err = await _run(
        "lsblk", "-J", "-b", "-d", "-o", "NAME,SIZE,MODEL,RM,TYPE")
    if code != 0:
        raise RuntimeError(f"lsblk failed: {err.strip()}")

    boot = await boot_disk()
    targets: List[Target] = []

    for dev in json.loads(out).get("blockdevices", []):
        if dev.get("type") != "disk":
            continue
        path = "/dev/" + dev["name"]
        size = int(dev.get("size") or 0)
        is_boot = path == boot

        eligible, reason = True, ""
        if is_boot:
            eligible, reason = False, "this is the device PENTA is running from"
        elif size < MIN_TARGET_BYTES:
            eligible, reason = False, "too small (needs 20 GB or more)"

        targets.append(Target(
            device=path,
            size_bytes=size,
            model=(dev.get("model") or "").strip() or "unknown",
            removable=bool(dev.get("rm")),
            is_boot=is_boot,
            eligible=eligible,
            reason=reason))

    return targets


class Installer:
    """Clone the running console onto a target disk.

    Progress is emitted as events rather than returned, because the write takes
    minutes and the menu has to stay responsive and show it happening.
    """

    def __init__(self, emit, mock: bool = False) -> None:
        self._emit = emit
        self._mock = mock
        self._running = False

    @property
    def running(self) -> bool:
        return self._running

    def confirmation_token(self, device: str) -> str:
        """What the user must send back to authorise the wipe.

        Naming the device means a stale or mistyped confirmation cannot destroy
        a disk the user was not looking at.
        """
        return "ERASE %s" % device.rsplit("/", 1)[-1].upper()

    async def install(self, device: str, confirm: str) -> Dict[str, object]:
        if self._running:
            raise RuntimeError("an install is already running")

        found = _mock_targets() if self._mock else await list_targets()
        targets = {t.device: t for t in found}
        target = targets.get(device)
        if target is None:
            raise ValueError(f"no such disk: {device}")
        if not target.eligible:
            raise ValueError(f"cannot install to {device}: {target.reason}")

        expected = self.confirmation_token(device)
        if confirm.strip().upper() != expected:
            raise ValueError(f"confirmation must be exactly: {expected}")

        source = MOCK_BOOT if self._mock else await boot_disk()
        if not source:
            raise RuntimeError("cannot determine which device PENTA booted from")
        if source == device:
            raise ValueError("source and target are the same device")

        self._running = True
        asyncio.create_task(self._clone(source, device, target.size_bytes))
        return {"started": True, "source": source, "target": device}

    async def _clone(self, source: str, target: str, target_size: int) -> None:
        try:
            self._emit("install.progress", stage="starting",
                       percent=0.0, source=source, target=target)

            if self._mock:
                for pct in range(0, 101, 10):
                    await asyncio.sleep(0.4)
                    self._emit("install.progress", stage="writing", percent=float(pct))
                self._emit("install.done", ok=True, target=target, mock=True)
                return

            size = _device_size(source)
            self._emit("install.progress", stage="writing", percent=0.0,
                       total_bytes=size)

            # dd's status=progress writes to stderr once a second; parse it
            # rather than guessing, so the bar reflects reality.
            proc = await asyncio.create_subprocess_exec(
                "dd", f"if={source}", f"of={target}",
                "bs=8M", "status=progress", "oflag=direct", "conv=fsync",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE)

            assert proc.stderr is not None
            buf = b""
            while True:
                chunk = await proc.stderr.read(256)
                if not chunk:
                    break
                buf += chunk
                # dd separates progress lines with \r
                while b"\r" in buf:
                    line, buf = buf.split(b"\r", 1)
                    copied = _parse_dd(line.decode(errors="replace"))
                    if copied and size:
                        self._emit("install.progress", stage="writing",
                                   percent=min(99.0, copied * 100.0 / size),
                                   copied_bytes=copied, total_bytes=size)

            if await proc.wait() != 0:
                raise RuntimeError("dd failed while writing the image")

            # The clone carries the source's partition table, whose backup
            # header sits where the smaller device ended. Move it, or the
            # target boots but reports a corrupt GPT and repart refuses to grow.
            self._emit("install.progress", stage="finishing", percent=99.0)
            if shutil.which("sgdisk"):
                code, _, err = await _run("sgdisk", "-e", target)
                if code != 0:
                    log.warning("sgdisk -e failed: %s", err.strip())

            await self._register_boot_entry(target)
            await _run("sync")
            self._emit("install.done", ok=True, target=target)
            log.info("installed to %s", target)

        except Exception as exc:                                # noqa: BLE001
            log.exception("install failed")
            self._emit("install.done", ok=False, error=str(exc))
        finally:
            self._running = False


    async def _register_boot_entry(self, target: str) -> None:
        """Add a firmware boot entry for the installed disk and make it first.

        The clone already carries EFI/BOOT/BOOTX64.EFI, which most firmware will
        boot as removable media — but that is a fallback, not a guarantee, and
        the machine may still have a stale entry ahead of it pointing at the
        operating system we just erased. An explicit NVRAM entry set first in
        BootOrder is what makes the machine boot PENTA and nothing else.

        Never fatal: a console that boots via the fallback path is still a
        console, and refusing to finish an otherwise good install over this
        would be worse than the problem.
        """
        if not shutil.which("efibootmgr"):
            log.warning("efibootmgr missing; relying on the removable-media path")
            return
        if not os.path.isdir("/sys/firmware/efi"):
            log.warning("not booted via UEFI; skipping boot entry")
            return

        # efibootmgr wants the disk and the ESP's partition number separately.
        esp_part = _esp_partition_number(target)
        if esp_part is None:
            log.warning("no ESP found on %s; skipping boot entry", target)
            return

        self._emit("install.progress", stage="registering boot entry", percent=99.5)

        # Drop any previous PENTA entries so reinstalling does not accumulate
        # a menu full of identical duplicates.
        code, out, _ = await _run("efibootmgr")
        if code == 0:
            for line in out.splitlines():
                if "PENTA" in line and line.startswith("Boot"):
                    num = line[4:8]
                    if num.isalnum():
                        await _run("efibootmgr", "-B", "-b", num)

        code, _, err = await _run(
            "efibootmgr", "--create",
            "--disk", target,
            "--part", str(esp_part),
            "--label", "PENTA",
            "--loader", "\\EFI\\BOOT\\BOOTX64.EFI")
        if code != 0:
            log.warning("could not create boot entry: %s", err.strip())
            return
        log.info("registered PENTA boot entry on %s partition %d", target, esp_part)


def _esp_partition_number(disk: str) -> Optional[int]:
    """Partition number of the EFI System Partition on a disk."""
    import subprocess
    try:
        out = subprocess.run(
            ["lsblk", "-J", "-o", "NAME,PARTTYPE", disk],
            capture_output=True, text=True, timeout=10).stdout
        tree = json.loads(out).get("blockdevices", [])
        kids = tree[0].get("children", []) if tree else []
        for i, part in enumerate(kids, start=1):
            if (part.get("parttype") or "").lower() == ESP_TYPE_GUID:
                return i
    except Exception as exc:                                    # noqa: BLE001
        log.warning("could not identify the ESP: %s", exc)
    return None


def _device_size(device: str) -> int:
    try:
        with open(device, "rb") as f:
            return f.seek(0, os.SEEK_END) or f.tell()
    except OSError:
        return 0


def _parse_dd(line: str) -> Optional[int]:
    """First field of a dd progress line is bytes copied."""
    line = line.strip()
    if not line or "bytes" not in line:
        return None
    head = line.split(" ", 1)[0]
    return int(head) if head.isdigit() else None
