# PENTA — Roadmap

Six milestones. Each one ends in something you can *see*, and each one is
independently valuable if you stop there. Do not skip M0.

---

## M0 — Prove the hardware (no custom code)

**Goal:** the Nitro 5 boots a stock Linux from the SanDisk, the RTX 3050 works,
a DualSense pairs. Nothing custom. This de-risks 80% of the project in an
evening.

Why first: every remaining milestone assumes external-USB boot, Nvidia, and
Bluetooth all work on *this specific laptop*. If one of them doesn't, you want
to know before you've written a UI.

1. **BIOS prep** (see `HARDWARE.md`): set Supervisor Password → disable Secure
   Boot → enable F12 Boot Menu → confirm USB boot allowed.
2. Write a live ISO to a spare USB stick. Use **Bazzite-Nvidia** even though we
   are building on Arch — it boots straight into a working Nvidia + gamescope
   session, so a failure points at *your hardware or BIOS* rather than at your
   own driver config. This is a diagnostic, not a commitment to the distro.
3. Boot it via F12. Verify, in order:
   - [ ] Firmware offers the SanDisk/USB as a boot device
   - [ ] It reaches a graphical session
   - [ ] `lsmod | grep nvidia` and `nvidia-smi` — dGPU alive
   - [ ] `glxinfo -B` / `vulkaninfo --summary` — render offload works
   - [ ] DualSense over **USB**: `evtest` shows buttons, gyro, touchpad
   - [ ] DualSense over **Bluetooth**: pairs via `bluetoothctl`, same devices
   - [ ] `cat /sys/class/power_supply/ps-controller-battery-*/capacity`
   - [ ] `gamescope -- vkcube` runs without exploding
   - [ ] Suspend/resume with the SSD attached — does the USB device survive?
4. **Record the results in `HARDWARE.md`.** Especially: exact model string,
   whether a MUX switch exists, USB port used, and any quirks.

**Exit criteria:** all boxes ticked, or a documented workaround for each miss.

**If gamescope-on-Nvidia fails here:** fall back to `cage` and note it. Do not
let this block M1.

---

## M1 — Minimum viable console

**Goal:** power on → black screen → logo → a controller-navigable grid of three
hardcoded tiles → press X → a game launches fullscreen → quit → back to the grid.

Ugly is fine. This is the skeleton.

### 1.1 Image build pipeline
- [x] `image/mkosi/mkosi.conf` — Arch, package list, systemd-boot, kernel cmdline.
- [x] `image/mkosi/mkosi.extra/` — `/etc` overlay: `penta.target`, `pentad.service`,
      greetd autologin, `penta-session`, udev rules, fstab, Plymouth theme.
- [x] Partition layout: ESP + root in the image; data + swap created on first
      boot by `systemd-repart` (no firstboot script of our own).
- [x] `.github/workflows/image.yml` — exports the menu with Godot, stages it,
      builds the image, publishes `penta-<sha>.img.zst`.
- [ ] **Run it.** Never executed; mkosi options shift between versions and this
      config has not been validated against a real build.
- [ ] Boot the resulting image on the Nitro 5.
- [ ] `.github/workflows/image.yml` — build on push, push to GHCR, attach
      `penta-<sha>.img.zst` to a release.
- [ ] `tools/flash.sh` — stream a release artifact to `/dev/rdiskN` on the Mac.
- [ ] **Boot the image you built.** This is the milestone's real test.

### 1.2 Session
- [ ] `penta-session.service` → `gamescope -e -f -- penta-menu`
- [ ] Kernel cmdline: `quiet loglevel=3 vt.global_cursor_default=0` — silent boot.
- [ ] Plymouth theme: black background, original logo, no text, no spinner-of-shame.
- [ ] Auto-login to an unprivileged `penta` user.
- [ ] Menu crash → systemd restarts it in <1s. Never drop to a TTY.

### 1.3 Daemon — **written, unverified on hardware**
- [x] `pentad` with 12 commands over TCP + Unix socket, event broadcast.
- [x] Title providers: Steam (`.acf`), native manifests, ROMs → RetroArch cores.
- [x] Session launching inside gamescope with PRIME render offload.
- [x] DualSense lightbar via raw HID (USB report 0x02 / BT 0x31 + CRC32).
- [x] Global PS-button watcher over evdev — works while a game holds focus.
- [x] `--mock` runs the whole thing on macOS.
- [ ] Verify evdev/hidraw paths on the real console. None of that code has met
      a controller yet.
- [ ] BlueZ pairing over D-Bus (M3).

### 1.4 Menu skeleton — **done**
- [x] Godot 4 project, 1920×1080, autoloads (`Tokens`, `Ipc`, `Router`).
- [x] `IpcClient` — JSON-lines over TCP, id-matched replies, interleaved events,
      auto-reconnect.
- [x] `InputRouter` — d-pad/stick nav with an accelerating repeat ramp,
      Cross/Circle swap flag, keyboard fallback for Mac development.
- [x] Card carousel with fixed-anchor scrolling, focus scale + ring, generated
      card art, ambient background that cross-fades to the focused title.
- [ ] Wire `confirm` to a real `title.launch` on hardware (needs 1.3).

**Exit criteria:** you can play a game, exit it, and land back on your own UI,
having never seen a desktop, a terminal, or a mouse cursor.

---

## M2 — A real library

**Goal:** the dashboard shows *your actual games*, with real key art.

- [ ] `titles/steam.py` — parse `.acf` manifests, resolve appids, launch via
      `steam://rungameid/`.
- [ ] `titles/native.py` — `penta.toml` manifests in `/games/native/`.
- [ ] `titles/rom.py` — scan `/games/roms/<system>/`, map to RetroArch cores.
- [ ] **Artwork service:** SteamGridDB fetch → cache in `/var/lib/penta/art/`;
      hero + logo + icon per title. Generated fallback card (dominant-colour
      gradient + typeset name) so nothing is ever broken.
- [ ] Library screen: grid, sort by recent/name/playtime, filter by provider.
- [ ] Persist `last_played` and `playtime_s` in SQLite at `/var/lib/penta/db`.
- [ ] Session lifecycle done properly: launch inside gamescope, track PID, detect
      exit, restore menu focus, no flicker to black desktop between the two.

**Exit criteria:** the home screen looks like a console you'd want to use, with
15+ of your own titles and correct art on every one.

---

## M3 — The console behaviours

**Goal:** the things that separate a console from a launcher.

- [ ] **PS button, globally.** `pentad` grabs it at the evdev layer so it works
      *during* a game. Short press → Control Center. Long press → power menu.
- [ ] **Control Center:** bottom strip overlaid on a blurred capture of what's
      running. Tiles: Sound, Controllers, Network, Downloads, Power, Close Game.
      Must never kill the running title.
- [ ] **Power menu:** Rest Mode / Restart / Power Off, with confirmations.
- [ ] **Rest Mode:** `suspend-then-hibernate`. Resume must land back in the same
      game. Lightbar pulses amber while resting. *(Validate the USB-SSD resume
      path found in M0.)*
- [ ] **Settings screens:** controllers (pair/unpair via BlueZ), network (Wi-Fi
      via NetworkManager D-Bus), display (resolution/refresh/HDR), storage
      (usage by category, delete titles), system (about, update, restore).
- [ ] **Volume/brightness** with an on-screen overlay, bound to R1/L1 in Control
      Center and to the laptop's own keys.
- [ ] **Notifications/toasts:** download finished, controller battery low,
      screenshot saved.

**Exit criteria:** you can do a full session — boot, play, PS button, adjust
volume, rest, resume, quit — without a keyboard ever entering the room.

---

## M4 — Make it beautiful

**Goal:** the polish pass. This is the milestone that makes it feel like a PS5
rather than a nice launcher. Budget more time here than feels reasonable.

- [ ] **Motion design pass.** Every transition ≤ 250 ms, ease-out, nothing
      linear. Card focus: scale 1.0→1.08 + elevation + rim light in 120 ms.
      Screen changes: cross-fade + 8 px parallax, never a hard cut.
- [ ] **Living background.** The focused title's hero art, heavily blurred and
      slowly drifting, with a subtle animated gradient mesh underneath. Cross-
      fades on focus change. This one effect carries most of the "expensive"
      feeling.
- [ ] **Depth system.** One consistent elevation scale (4 levels, defined once);
      blur radius and shadow tied to elevation. No ad-hoc shadows.
- [ ] **Sound design.** Original: nav tick, confirm, back, error, boot chime,
      Control Center open/close. Quiet, short, low-frequency. Ducked when a game
      is running.
- [ ] **Haptics + lightbar.** Nav tick = 15 ms low rumble. Lightbar takes the
      dominant colour of the focused title's art. Player LED on pair.
- [ ] **Boot sequence.** Plymouth logo → menu fade-in must be seamless: same
      background colour, no flash, no resolution change. Target <8 s to home.
- [ ] **Typography.** One geometric sans, three weights, a strict type scale.
      Not Inter. (Sora / Manrope / Geist are good starting points.)
- [ ] **Accessibility:** contrast ≥ 4.5:1 on all text, focus always visible
      without relying on colour alone, `reduced-motion` toggle that shortens
      rather than removes transitions.

**Exit criteria:** someone who doesn't know what it is asks what console that is.

---

## M5 — Extras

Pick from this list based on what you actually want.

- [ ] **Optical disc support.** udev rule on `/dev/sr0` → `pentad` reads the
      ISO9660/UDF volume label → a "disc" card appears on the home row with a
      spin-up animation. Launches homebrew/self-made content from the disc.
- [ ] **Captures.** Screenshot + rolling 60 s video buffer (GPU-encoded via
      `gpu-screen-recorder`), bound to the Create button, with a gallery screen.
- [ ] **Trophies.** Map Steam achievements into a PS-style trophy list with
      rarity and a slide-in unlock toast.
- [ ] **Profiles.** Multiple users, per-user library and settings, avatar picker.
- [ ] **Updates.** `bootc upgrade` behind a Settings → System → Update screen,
      with a progress UI and automatic btrfs snapshot + one-click rollback.
- [ ] **Remote Play–ish.** Sunshine host so you can stream the console to a
      phone/tablet on the LAN.
- [ ] **Secure Boot.** `sbctl`-signed UKIs so you can leave Secure Boot on.
- [ ] **Store.** A "store" tab that's really a curated open-source/itch.io
      homebrew browser with one-click install.

---

## Suggested order of attack, week by week

| Week | Focus |
|---|---|
| 1 | M0 end-to-end. Do not write UI code yet. |
| 2 | M1.1 + M1.2 — image builds in CI, flashes, boots to a black screen with your logo. The menu is already written; this is about getting it *on* the machine. |
| 3 | M1.3 — real `pentad` on the console; wire the menu to it. **First playable.** |
| 4–5 | M2 — real library, real art. |
| 6–7 | M3 — PS button, Control Center, Rest Mode, settings. |
| 8+ | M4 — polish, indefinitely. This is the fun part; don't rush to M5. |

**The trap to avoid:** starting with the beautiful UI. The UI is the easiest and
most rewarding part, which is exactly why it's dangerous to start there — you'll
build something gorgeous that has nowhere to run. M0 → M1 is unglamorous
plumbing and it's what makes the rest possible.
