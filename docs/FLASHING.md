# PENTA — Flashing from the Mac

> **If you have no USB media**, you don't need this document — see
> [INSTALL-NO-USB.md](INSTALL-NO-USB.md), which installs straight to the
> laptop's NVMe from a RAM-booted live system. This page is for writing PENTA
> to a USB SSD from the Mac.

## Which of the three routes you want

| | Stick needed | Use it when |
|---|---|---|
| **Installer** (below) | any, 8 GB+ | you want PENTA on the laptop's internal NVMe |
| **Direct image** (rest of this page) | 32 GB+ | you want to *run* PENTA off a USB SSD |
| [**No USB at all**](INSTALL-NO-USB.md) | none | you have no removable media |

The two are different jobs and the size rule is different for each. Writing the
console image straight to a stick means the stick *is* the console, so it has
to hold the whole 14 GiB OS plus room for `systemd-repart` to add swap and a
data partition — hence 32 GB. Using a stick to get PENTA onto an internal disk
makes it a courier, and a courier only carries the ~2 GB compressed file.

---

## The installer

A separate ~400 MB bootable image ([`image/installer/`](../image/installer))
that writes the console image onto an internal disk. It is not PENTA and does
not contain PENTA — the console image rides along beside it on the stick.

**1. Flash the installer** to any stick, 8 GB or larger:

```bash
sudo ./tools/flash-usb.sh penta-installer-*.img.xz diskN
```

**2. Copy the console image onto it.** A volume named `PENTA_PAYLOAD` appears
in Finder. Drag `penta-<sha>.img.xz` onto it and eject. That is the entire
manual step — no `dd`, no partition arithmetic.

**3. Boot the stick** (F12 on an Acer). The installer lists every disk, refuses
its own stick and anything under 24 GB, shows you what is currently on the
target, and makes you type out `ERASE NVME0N1` before it writes anything.

Why the two files stay separate: the console image is ~2 GB and GitHub rejects
release assets over 2 GiB, so an installer with it baked in could not be
published at all. It also means a new console image needs no new installer —
drop the new file on the same stick.

Build one with the **build installer** workflow (manual trigger; it is not run
on every push).

---

## Writing the console image directly to a USB SSD

## The constraint that shapes this

Your Mac has **8.2 GB free**. A PENTA image is ~25 GB raw / ~0.5 GB compressed.
The raw form does not fit, and it doesn't need to: the image is **streamed**
from GitHub and decompressed in a pipe, never touching your internal disk.

```
curl (GitHub release) → zstd -d → dd → /dev/rdiskN
```

Peak local disk usage: zero. Peak memory: a few MB of pipe buffer.

## One-time setup

```bash
brew install zstd pv
```

`pv` is optional but gives you a progress bar; BSD `dd` otherwise only reports
progress when you press **Ctrl-T**.

## Flashing

1. Plug in the SanDisk. **Everything on it is destroyed** — it currently has
   your Kali install on it.
2. Find the device:

```bash
diskutil list external physical
```

3. Run the flasher with the *disk* identifier (e.g. `disk6`, not `disk6s1`):

```bash
./tools/flash.sh disk6
```

It will show you what it's about to erase, make you type the disk identifier
back, and only then write. Expect 10–25 minutes depending on the port.

4. `diskutil eject disk6`, plug into the Nitro 5, tap **F12**, pick the SanDisk.

## What happens on first boot

The flashed image is ~25 GB, so the SSD arrives with ~975 GB unallocated and a
GPT whose backup header is sitting in the middle of the disk where `dd` left it.

**`systemd-repart` fixes both, and we wrote no code for it.** It runs early in
boot, reads the partition definitions shipped at
`/usr/lib/repart.d/`, and against the *real* disk:

1. Relocates the GPT backup header to the true end of the device.
2. Creates `PENTA_DATA` (btrfs) filling the free space, with the `games`,
   `captures` and `art` subvolumes.
3. Creates `PENTA_SWAP`, sized for hibernation so Rest Mode can resume.

It then never does anything again, because the partitions it wants now exist.
No firstboot flag file, no idempotency logic of ours to get wrong.

First boot takes maybe 30 s longer than normal. Every boot after goes straight
to the menu.

## Recovering / re-flashing

Re-running `flash.sh` wipes and re-images. Because `PENTA_DATA` is created at
first boot rather than shipped in the image, **re-flashing destroys your game
library too**. If you want a fast OS-only reinstall path later, that's what
`bootc` rebase + rollback is for (M5) — use that, not re-flashing.

## Troubleshooting

| Symptom | Cause |
|---|---|
| SSD not offered at F12 | F12 Boot Menu not enabled in BIOS, or Fast Boot on |
| "Secure Boot violation" | Secure Boot still enabled — needs Supervisor Password first |
| Boots to a text console | Session unit failed — check `journalctl -u penta-session` |
| Black screen, no signal | Nvidia modeset — try removing `nvidia_drm.fbdev=1` |
| Very slow boot / I/O | Plugged into a 5 Gbps port, or UAS disabled by a quirk |
