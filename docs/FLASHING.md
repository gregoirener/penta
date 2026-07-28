# PENTA — Flashing from the Mac

> **If you have no USB media**, you don't need this document — see
> [INSTALL-NO-USB.md](INSTALL-NO-USB.md), which installs straight to the
> laptop's NVMe from a RAM-booted live system. This page is for writing PENTA
> to a USB SSD from the Mac.

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
