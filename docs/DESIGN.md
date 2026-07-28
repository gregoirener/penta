# PENTA — Technical Design

> A console-style operating environment for PC hardware. Original code, original
> assets, open-source stack. Boots from an external SSD; never touches Windows.

**Codename:** PENTA · **Menu:** `penta-menu` · **Daemon:** `pentad` · **Image:** `penta-image`

---

## 0. Target hardware & build environment (the real constraints)

| | |
|---|---|
| **Target machine** | Acer Nitro 5, RTX 3050 Laptop (hybrid graphics), Windows on internal NVMe |
| **Console storage** | The laptop's internal NVMe, whole disk. Windows removed. |
| **Dev machine** | MacBook, **Apple Silicon (arm64)**, macOS 26.5, **8.2 GB free on `/`** |

Three findings from the dev machine that shape the whole build strategy:

1. **The Mac is arm64; the target is x86_64.** Building a full x86_64 Linux
   userspace locally means QEMU emulation — hours per build, for something CI
   does in minutes. We do not build the OS on the Mac.
2. **8.2 GB free is not enough to store a disk image.** A console image is
   10–25 GB raw. We never land it on the Mac's disk at all.
3. **No podman/docker/qemu installed.** Nothing to fix — we don't need them.

### The build strategy this forces (and it's the *good* one)

```
  ┌────────────────────────────┐
  │  GitHub Actions (x86_64)   │   builds the OS image, publishes a
  │  penta-image → ghcr.io     │   compressed raw .img.zst as a release
  └──────────────┬─────────────┘
                 │  curl (streamed, never stored)
                 ▼
  ┌────────────────────────────┐
  │  Mac: flash.sh             │   curl | zstd -d | dd → /dev/rdiskN
  │  0 bytes written to disk   │
  └──────────────┬─────────────┘
                 ▼
  ┌────────────────────────────┐
  │  SanDisk 1 TB SSD          │   plug into Nitro 5 → F12 → boot PENTA
  └────────────────────────────┘
```

Your "build here, flash here, plug in, boot" workflow survives intact — the
*build* just happens on a free x86_64 runner instead of under emulation, and the
image streams through the Mac rather than sitting on it.

**The UI is a different story.** Godot runs natively on Apple Silicon, so the
menu is developed, run and iterated on the Mac at full speed, then `rsync`'d to
the console over SSH in ~2 seconds. You will spend 95% of your time in that
loop and almost never rebuild the OS image.

---

## 1. Layer model

```
┌─────────────────────────────────────────────────────────────────┐
│ L4  CONTENT      Steam · Proton · RetroArch · homebrew · discs   │
├─────────────────────────────────────────────────────────────────┤
│ L3  MENU         penta-menu (Godot 4) — dashboard, Control      │
│                  Center, library, settings. The "console".       │
├─────────────────────────────────────────────────────────────────┤
│ L2  RUNTIME      pentad (system daemon) · gamescope compositor   │
│                  input arbitration · power · storage · titles    │
├─────────────────────────────────────────────────────────────────┤
│ L1  BASE OS      Arch (mkosi disk image) · Nvidia · systemd ·    │
│                  BlueZ · PipeWire · Plymouth                     │
├─────────────────────────────────────────────────────────────────┤
│ L0  BOOT         systemd-boot on the SSD's own ESP               │
└─────────────────────────────────────────────────────────────────┘
```

The hard boundary is **L2 ↔ L3**. `pentad` owns everything privileged and
stateful; `penta-menu` is a pure client over a socket. That means the
whole UI can be restarted, replaced, crashed or rewritten in a different
language without taking the console down — and it's why the UI framework choice
is reversible.

---

## 2. L0 — Boot

**Decision (revised 2026-07-28): PENTA owns the internal NVMe outright.
Windows is removed. There is no dual-boot.**

The original design put PENTA on an external SSD and never wrote a byte to the
internal disk, which made "revert" mean *unplug the drive*. The user chose the
internal drive instead, with the consequences stated and accepted.

What that costs us, recorded so nobody is surprised later:

- **No fallback OS.** A PENTA image that fails to boot leaves a machine that
  boots nothing. Recovery requires external media.
- **No reversibility.** Windows and everything on the drive are gone.
- **The safety argument for image-based updates gets stronger, not weaker.**
  With no second OS to fall back on, atomic updates and a bootable previous
  image stop being a nicety. See M5.

What stays the same: `systemd-boot` on the ESP, a single kernel command line, no
GRUB. The whole drive is ours, so there is no foreign partition table to respect
and no shared ESP to corrupt — which is genuinely simpler than the dual-boot
case, and the one thing this choice makes *easier*.

**Because there is no fallback, buy a USB stick.** A 16 GB stick is the
difference between "reflash and retry" and "the laptop is a brick until I can
get to a shop". Not required to install — see `INSTALL-NO-USB.md` — but the
first time an image doesn't boot, it is the only way back.

Why `systemd-boot` over GRUB: it reads the ESP directly, needs no `grub-install`
into a device MBR, has a trivially simple config, and pairs cleanly with Unified
Kernel Images later (which is what makes Secure Boot signing easy if we ever
want it).

**Acer-specific gotchas** (these are the #1 cause of "my USB doesn't show up"):

1. The F12 boot menu is **disabled by default** on Acer — enable `F12 Boot Menu`
   in BIOS → Main.
2. Secure Boot cannot be disabled until you **set a Supervisor Password** in
   BIOS → Security. Set it, disable Secure Boot, then you may clear it.
3. If the internal NVMe is in **Intel RST / RAID mode** it's invisible to Linux
   — irrelevant for us (we boot external, we don't touch it), but it's why
   "install Linux to the internal disk" guides fail on this machine.

Secure Boot must be **off** for the Nvidia proprietary kernel modules to load
unsigned. Signing them (`sbctl`, MOK enrolment) is a later polish item, not an
MVP concern.

---

## 3. L1 — Base OS

**Decision: Arch, bootstrapped ourselves, built into a disk image with `mkosi`.**

Chosen over a Bazzite/Fedora-Atomic derivative deliberately. The trade is real
and worth stating plainly:

- **What we give up:** Bazzite ships a *working* hybrid Nvidia + Wayland +
  gamescope stack for exactly this class of laptop. Taking Arch means that
  integration — and every kernel update that breaks it — is ours to own. This is
  the single biggest source of future pain in the project.
- **What we get:** an image that contains only what we put in it (~2 GB rather
  than ~10 GB), a boot path we can read end to end, and no fight against another
  project's opinions every time we want to change the session. When the console
  misbehaves at 1 a.m., we will know why.

**`mkosi`** is the build tool: it bootstraps a distro into a GPT disk image with
systemd-boot, runs entirely in a container on an x86_64 CI runner, and is
declarative enough to diff. It supports Arch as a first-class target.

```conf
# image/mkosi/mkosi.conf (sketch)
[Distribution]
Distribution=arch

[Output]
Format=disk
Bootable=yes

[Content]
Bootloader=systemd-boot
Packages=
	base linux linux-firmware
	nvidia nvidia-utils lib32-nvidia-utils egl-wayland
	gamescope pipewire pipewire-pulse wireplumber
	bluez bluez-utils
	python python-evdev python-dbus-next hidapi
	btrfs-progs plymouth openssh
```

Nvidia notes for this machine specifically:
- Use the **`nvidia`** package (prebuilt against the stock `linux` kernel), not
  `nvidia-dkms` — DKMS in an image build means compiling the module at image
  time for a kernel we control anyway, which is pure cost.
- The RTX 3050 is Ampere, so **`nvidia-open`** is also a valid choice and is
  where Arch is heading. Worth trying if the proprietary module misbehaves.
- Pin the kernel and the Nvidia package **in the same image build**. The classic
  Arch failure is a kernel update landing without a matching module; because our
  OS is a built image rather than a rolling install, this is impossible by
  construction — a nice side effect of the image approach.

**Kernel:** stock Arch `linux`. It already carries `hid-playstation` (mainline
since 5.12) and the i915/amdgpu bits. No custom kernel config in the MVP.
Boot params we do set:

```
quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0
nvidia_drm.modeset=1 nvidia_drm.fbdev=1
```

The last four are what make the boot *silent and black* instead of a wall of
scrolling systemd text — a surprisingly large fraction of "console feel".

---

## 4. L2 — Runtime

### 4.1 gamescope as the session compositor

`gamescope` is Valve's micro-compositor: it owns the display, renders exactly
one fullscreen client at a time, and gives us for free the things that make a
console feel like a console —

- **Atomic mode-setting and tear-free presentation.** No desktop, no window
  decorations, no possibility of a stray dialog appearing.
- **Resolution decoupling:** the menu always renders at native panel res while
  a game can render at 1080p/720p and be upscaled (FSR/NIS) — this is precisely
  how consoles ship dynamic-resolution titles.
- **Frame limiting** per-title, which is how you get a stable 60 instead of a
  jittery 90.
- **Seamless app switching** without ever showing a black desktop.

Session startup:

```
penta.target
 └─ penta-session.service
     └─ gamescope -e -f -W 1920 -H 1080 -r 60 --  penta-menu
```

Honest risk: gamescope on **Nvidia** is meaningfully less battle-tested than on
AMD (the Steam Deck is AMD). Expect to hit at least one Nvidia-specific bug.
The fallback, if it fights us, is `cage` (a minimal Wayland kiosk compositor) or
plain Wayland+`labwc` in kiosk mode — we lose upscaling and frame limiting but
keep the kiosk behaviour. This is why the menu must not depend on gamescope
APIs directly.

### 4.2 `pentad` — the system daemon

The piece that turns "a Linux box running a fullscreen app" into "a console".
Everything privileged lives here, behind one socket.

**Responsibilities:**

| Service | What it does |
|---|---|
| **Input arbitration** | Reads all `/dev/input/event*` via evdev. Owns the **PS button** globally — short press → Control Center, long press → power menu — *even while a game is fullscreen and grabbing input*. This is the trick that makes it feel like a real console rather than a launcher. |
| **DualSense extras** | Lightbar colour, player LEDs, adaptive-trigger effects, battery — via raw HID output reports (`hidapi`). The kernel driver does not expose triggers; nothing but raw reports will. |
| **Bluetooth** | Pairing/unpairing/trust over BlueZ D-Bus, so pairing happens *inside* our UI (controller-navigable), never in a desktop settings app. |
| **Power** | Rest mode (`suspend-then-hibernate`), clean shutdown, restart, "close application". |
| **Titles** | Aggregates the title providers (§5) into one library, caches artwork. |
| **Storage** | Reports usage per category, manages the games subvolume, mounts discs. |
| **Sessions** | Launches a title inside gamescope, tracks it, kills it, returns focus to the menu. |

**Language: Python 3** for now (`python-evdev`, `dbus-next`, `hidapi`,
`pyudev` — all mature, all packaged). Latency is a non-issue at menu scale.
The IPC boundary is deliberately language-agnostic so a Rust rewrite later is a
drop-in — it is the *protocol* that matters, not the implementation.

**IPC: newline-delimited JSON over TCP loopback `127.0.0.1:8787`.**
A Unix socket would be the tidier choice, but Godot 4 has no Unix-domain
socket class — only `StreamPeerTCP` — and a loopback socket keeps the menu code
identical on macOS and on the console. `pentad` additionally exposes
`/run/penta/pentad.sock` for privileged CLI tools. Loopback-only, no external
bind. Trivially debuggable with `socat`, trivially mockable on the Mac.

```jsonc
// menu → daemon
{"id":7,"cmd":"library.list","args":{}}
{"id":8,"cmd":"title.launch","args":{"uid":"steam:1245620"}}
{"id":9,"cmd":"power.rest","args":{}}
{"id":10,"cmd":"led.set","args":{"r":32,"g":92,"b":255}}

// daemon → menu (unsolicited events share the channel, id = null)
{"id":null,"event":"input.ps_button","args":{"kind":"short"}}
{"id":null,"event":"controller.battery","args":{"pct":38,"charging":false}}
{"id":null,"event":"title.exited","args":{"uid":"steam:1245620","code":0}}
{"id":null,"event":"disc.inserted","args":{"label":"HOMEBREW_01"}}
```

**Mock mode is a first-class feature.** `pentad --mock` runs on macOS with
fake titles, fake battery, fake events. That's what makes Mac-side UI iteration
possible at all, and it should exist from day one.

---

## 5. Titles: how games get into the library

A `TitleProvider` interface, one implementation per source. Each returns a
normalised record; the menu never knows where a game came from.

```python
@dataclass
class Title:
    uid: str            # "steam:1245620" | "rom:snes:chrono" | "native:mygame"
    name: str
    provider: str
    launch: list[str]   # argv, executed inside gamescope
    art: Art            # hero, logo, icon, background colour
    last_played: float | None
    playtime_s: int
```

| Provider | Source | Notes |
|---|---|---|
| `steam` | `~/.steam/steam/steamapps/*.acf` | Launch via `steam steam://rungameid/<id>`. Proton handles Windows titles. Achievements later become "trophies". |
| `heroic` | Heroic/Legendary config | Epic + GOG. Optional. |
| `rom` | `/games/roms/<system>/` | Dispatch to RetroArch cores. Systems inferred from directory. |
| `native` | `/games/native/*/penta.toml` | Your own homebrew. A 6-line manifest and it appears on the dashboard as a first-class title. |
| `disc` | udev + ISO9660/UDF label | §7. |

**Artwork is the entire visual identity of the dashboard.** A PS5 home screen is
90% key art. Use **SteamGridDB** (free API key) for hero/logo/icon per title,
cached to `/var/lib/penta/art/`. A title without art gets a generated card:
dominant-colour gradient + typeset name. Never show a broken image.

---

## 6. Storage abstraction

Partition layout on the internal NVMe (whole disk):

| # | Size | FS | Label | Purpose |
|---|---|---|---|---|
| 1 | 1 GiB | FAT32 | `PENTA_ESP` | ESP: systemd-boot + UKIs |
| 2 | 64 GiB | btrfs | `PENTA_SYS` | OS image (ostree), `@`, `@var` |
| 3 | rest of disk | btrfs | `PENTA_DATA` | `games`, `art`, `captures` subvolumes |
| 4 | 20 GiB | swap | `PENTA_SWAP` | hibernation target for Rest Mode |

Rationale:

- **btrfs subvolumes, not partitions**, for everything user-facing. The menu
  can then report "Games: 412 GB / Captures: 8 GB / System: 31 GB" against one
  pool, which is exactly the console mental model — one big internal drive, no
  visible partitions, no "disk full on C:".
- **`compress=zstd:1`** on `@games` — typically 10–20% saved on game assets for
  negligible CPU, and it *increases* effective read throughput over USB, which
  is the bottleneck here.
- **Snapshots as system restore.** `@` is snapshotted before every OS update.
  "Restore console to previous version" becomes a menu item that actually works.
- **The swap partition exists for Rest Mode.** `suspend-then-hibernate` gives
  the real console behaviour: instant resume for the first N hours, then a
  silent transition to zero-power hibernation, resuming to exactly the same
  game. This is a genuinely achievable console feature that most PC "big picture
  modes" don't have.

The image we flash is only ~24 GiB; partition 3 is created and grown on **first
boot** by a `penta-firstboot.service`. That keeps the streamed download small.

**On internal NVMe this gets simpler.** The USB-bridge worries that shaped the
original design — UAS quirks, enclosures dropping off the bus across
suspend/resume, ~1000 MB/s ceiling — all disappear. Rest Mode's resume path is
now an ordinary NVMe hibernate, which is the well-trodden case. One of the few
places the internal-disk decision genuinely helps.

---

## 7. Controllers

### Stack

```
DualSense ──USB──┐
                 ├─→ hid-playstation (kernel) ─→ evdev ─→ Godot input
DualSense ──BT───┘        │
                          └─→ raw hidraw ─→ pentad ─→ lightbar / triggers / battery
```

- **USB and Bluetooth both work out of the box** with mainline `hid-playstation`
  (5.12+): buttons, sticks, triggers, touchpad (as a separate multitouch
  device), gyro/accel (separate evdev node), rumble (force-feedback), battery.
- **Pairing** is `Create + PS` on the controller, then BlueZ agent → our UI.
  `pentad` drives BlueZ over D-Bus so pairing never leaves the console shell.
- **Adaptive triggers and lightbar are *not* in the kernel API.** They require
  raw HID output reports (report 0x02 USB / 0x31 BT, with CRC32 on BT). This is
  well-documented publicly and there are clean open-source references
  (`dualsensectl`, SDL3's `SDL_SendGamepadEffect`). `pentad` owns this.
- **Haptics** (the DualSense's voice-coil actuators) are exposed only as classic
  rumble through the kernel FF interface. True per-effect haptics need audio-
  channel tricks — out of scope; classic rumble is plenty for a menu.

### Shell-side feel

Godot on Linux reads evdev directly (it does not use SDL there), so it gets
buttons/sticks/rumble natively and delegates lightbar/triggers to `pentad`.
Design the UI input layer as a **single `InputRouter`** with a virtual button
vocabulary (`confirm`, `back`, `option`, `nav_*`, `l1`, `r1`, `ps`) so that:

- Cross/Circle confirm-swap is one flag, not 40 call sites.
- Keyboard fallback exists for development on the Mac.
- Every navigation event can fire haptics + a UI sound from one place.

**Input feel is where this project is won or lost.** Non-negotiables:
- Repeat-rate ramp on held stick/d-pad (~400 ms initial, ~90 ms repeat).
- Focus movement animates in ≤120 ms with an ease-out curve; never linear.
- Every focus change: a soft click sound + a ~15 ms low-amplitude rumble tick.
- Never block input during a transition — queue and coalesce instead.

---

## 8. The menu (L3)

### Framework: Godot 4.x

Reasons, in order of weight:

1. **Gamepad input is the native idiom**, not an afterthought bolted onto a
   pointer-first framework.
2. **Animation and shaders are the product here.** The PS5 look is blur, depth,
   parallax, a living background, cards that scale and cast light. `AnimationPlayer`
   + `Tween` + a `BackBufferCopy` blur shader gets you there in hours.
3. **A single self-contained binary**, ~60 MB, starts in well under a second,
   uses ~150 MB RAM. An Electron app is 300+ MB and adds a compositing hop.
4. **It runs natively on your Apple Silicon Mac**, so the iteration loop is local
   and instant.

The alternative — **React + Electron/CEF kiosk** — is genuinely viable (Steam's
own UI is CEF) and you'd be faster in it on day one given your Next.js
background. It loses on input latency, memory, and startup time; it wins on
your familiarity and on CSS being a better layout engine than Godot's Control
nodes. Because the menu is a thin socket client, **this choice is reversible**.

### Screens (MVP set)

```
boot        → Plymouth splash, black, original logo, ~2s
home        → top icon row (Store/Library/Settings/Profile)
              + large card carousel; focused card blooms, background
              cross-fades to that title's hero art
title       → hero, logo, Play CTA, playtime, options
library     → grid, sort/filter, controller-driven
control     → PS-button overlay: bottom strip, blurred backdrop over
              whatever's running, never leaves the game
power       → Rest Mode / Restart / Power Off
settings    → controllers, network, display, storage, system
```

### Directory layout

```
penta/
├── docs/                    DESIGN · ROADMAP · HARDWARE · FLASHING · LEGAL
├── image/                   OS image
│   ├── mkosi/
│   │   ├── mkosi.conf       distro, packages, bootloader
│   │   └── mkosi.extra/     → /etc overlay (systemd units, udev, plymouth)
│   └── partitions/          repart definitions (§6)
├── daemon/
│   └── pentad/
│       ├── ipc.py           socket server, JSON-lines protocol
│       ├── input.py         evdev arbitration, PS-button hotkey
│       ├── dualsense.py     hidraw: lightbar, triggers, battery
│       ├── power.py         rest / restart / shutdown
│       ├── storage.py       btrfs usage, disc mounting
│       ├── titles/          steam.py · rom.py · native.py · disc.py
│       └── mock.py          --mock for macOS development
├── menu/                   Godot 4 project
│   ├── core/                InputRouter · IpcClient · Theme · Audio
│   ├── screens/             home · title · library · control · power · settings
│   ├── widgets/             GameCard · IconRow · Toast · Meter
│   └── assets/              original art, fonts, sounds
├── tools/
│   ├── flash.sh             stream image → SSD from the Mac
│   ├── devsync.sh           rsync menu build → console, restart service
│   └── mock-server.py       run pentad in mock mode locally
└── .github/workflows/       image build → GHCR + release artifact
```

---

## 9. Prior art worth stealing from

| Project | Take |
|---|---|
| **Bazzite** / Universal Blue | Not our base, but *read their Nvidia + gamescope config* — it is the reference for what working looks like on this hardware. |
| **ChimeraOS** | `frzr` image updates, `gamescope-session` structure. Read its session units. |
| **gamescope** | The compositor itself. Don't reimplement. |
| **SteamOS / Holo** | The reference for "session replaces desktop". |
| **Batocera / EmulationStation-DE** | ROM scanning, systems metadata, scraper logic. |
| **dualsensectl** | Reference implementation for DualSense HID output reports. |
| **SteamGridDB** | Artwork API — the thing that makes the dashboard look expensive. |
| **Plymouth** | Boot splash. Write a small original theme. |

---

## 10. Explicit non-goals

Stated once so scope stays honest:

- No Sony firmware, files, fonts, icons, logos, sounds, or system software.
- No emulation of PS5 hardware, no attempt to run commercial PS5 titles.
- No hardware or identity spoofing.
- The UI is **PS5-*inspired***: same design language (dark, spatial, card-first,
  large key art, blurred overlays), entirely original assets. Keep it private;
  don't ship Sony's trade dress under their name. See `LEGAL.md`.
- Not a Windows replacement. Windows stays untouched and is one unplug away.
