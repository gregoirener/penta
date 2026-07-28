# PENTA

A console-style operating environment for PC hardware: an Arch image, a
gamescope session, and a controller-first menu instead of a desktop. It takes
over the whole machine — there is no desktop and no second OS.

Original code, original assets, open-source stack. Not affiliated with anyone.
See [LEGAL.md](docs/LEGAL.md).

```
power on ──→ PENTA        (that's it — PENTA owns the drive)
```

## Docs

| | |
|---|---|
| [DESIGN.md](docs/DESIGN.md) | Architecture: boot, base OS, runtime, menu, storage, controllers |
| [ROADMAP.md](docs/ROADMAP.md) | M0 → M5, week by week |
| [INSTALL-NO-USB.md](docs/INSTALL-NO-USB.md) | **Start here** — installing with no USB media |
| [M0-RUNBOOK.md](docs/M0-RUNBOOK.md) | Optional manual hardware check (now automated on first boot) |
| [HARDWARE.md](docs/HARDWARE.md) | Acer Nitro 5 + RTX 3050 + SanDisk specifics, BIOS steps |
| [FLASHING.md](docs/FLASHING.md) | Streaming an image to the SSD from a Mac |
| [LEGAL.md](docs/LEGAL.md) | What we build vs. what we never touch |

## Shape of the thing

```
L4  content    Steam · Proton · RetroArch · homebrew · discs
L3  menu       penta-menu   (Godot 4)  — dashboard, Control Center, library
L2  runtime    pentad (daemon) · gamescope — input, power, titles, storage
L1  base       Arch, built into a disk image with mkosi · Nvidia · BlueZ
L0  boot       systemd-boot on the NVMe's ESP
```

The menu talks to the daemon over one socket (JSON lines, TCP loopback).
Everything privileged lives in the daemon; the UI is a replaceable client — it
can crash, restart, or be rewritten in another language without the console
going down.

## Dev loop

The Mac is arm64 and the target is x86_64, so **the OS image builds in CI** and
streams to the SSD without ever landing on local disk. The **menu is developed
natively on the Mac** against the real daemon in mock mode, then rsync'd to the
console. `pentad --mock` is the same daemon with fake hardware and a fake
library — not a separate stub — so the protocol cannot drift.

```bash
cd daemon && python3 -m pentad --mock
```

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path menu
```

Arrow keys navigate, Enter confirms, Escape backs out — so the whole UI is
workable without a controller plugged in. Plug in a DualSense and it just works.

Render a frame to a PNG without opening a window (handy for checking a change,
or for diffing the UI across commits):

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path menu -- /tmp/shot.png
```

Other tools:

```bash
./tools/flash.sh disk6
```

```bash
./tools/devsync.sh penta.local
```

## Status

Written and running on the Mac:

- **Menu (M1.4)** — card carousel with fixed-anchor scrolling, focus animation,
  generated card art, ambient background that cross-fades to the focused title,
  gamepad + keyboard input with an accelerating repeat ramp.
- **Daemon (M1.3)** — 12 commands, Steam/native/ROM title providers, gamescope
  session launching with PRIME offload, DualSense lightbar over raw HID, global
  PS-button watcher, power/storage services. `--mock` runs it all on macOS.
- **Image (M1.1)** — mkosi config, repart layout, systemd units, greetd
  autologin session, Plymouth theme, CI workflow.

**None of it has touched the Nitro 5 yet, and the image has never been built.**
Next step is [M0](docs/M0-RUNBOOK.md) — boot a stock live ISO from the SanDisk
and confirm the hardware cooperates. The image build also needs its first CI run
to shake out; mkosi options move between versions.

## Layout

```
docs/     design, roadmap, hardware notes, flashing, ground rules
image/    mkosi config → bootable Arch disk image (built in CI)
daemon/   pentad — input arbitration, power, titles, storage
menu/     Godot 4 project — the console UI
tools/    flash.sh · devsync.sh · make-logo.py
```
