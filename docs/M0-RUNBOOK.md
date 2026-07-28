# M0 — Hardware runbook

Exactly what to do, in order. No PENTA code involved. Budget one evening.

**You need:** the Nitro 5, a spare USB stick (8 GB+), a DualSense, the Ethernet
cable or Wi-Fi password, and about 90 minutes. **Not** the SanDisk — leave it
unplugged until step 5.

---

## Step 1 — Back up the SanDisk (5 min)

It currently holds your Kali install. Everything on it dies in M1.

```bash
diskutil list external physical
```

Copy off anything you care about now. There is no later.

---

## Step 2 — Make the live USB (15 min)

Download **Bazzite (Nvidia, desktop)** from https://bazzite.gg — pick the
`nvidia-open` ISO if offered for RTX 30-series, otherwise the standard Nvidia
one.

> We build on Arch, but this ISO boots straight into a working Nvidia +
> gamescope session. If something fails here, the cause is your hardware or
> BIOS, not your driver config. That separation is the whole point of M0.

Write it with [balenaEtcher](https://etcher.balena.io) (simplest), or:

```bash
diskutil unmountDisk /dev/disk6 && sudo dd if=~/Downloads/bazzite.iso of=/dev/rdisk6 bs=4m status=progress
```

Replace `disk6` with your USB stick — **check twice**, this erases it.

---

## Step 3 — BIOS setup (10 min)

Power on and tap **F2** repeatedly.

1. **Security** → `Set Supervisor Password` → set one. **Write it down.**
   *(Acer will not let you change Secure Boot without this. It's not optional.)*
2. **Boot** → `Secure Boot` → **Disabled**.
   *(Required for the Nvidia kernel modules to load. We can sign them later.)*
3. **Main** → `F12 Boot Menu` → **Enabled**.
   *(Off by default. Without it there's no boot-device picker at all.)*
4. **Main** → `Fast Boot` → **Disabled** if present. Helps USB detection.
5. **F10** to save and exit.

Leave everything else alone — especially any SATA/NVMe mode setting. Windows
needs it exactly as it is.

---

## Step 4 — Boot the live USB (5 min)

Power on → tap **F12** → pick the USB stick.

**If the USB isn't listed:** re-check F12 Boot Menu is enabled, Secure Boot is
off, and try the other USB ports (avoid hubs).

Let it boot to the desktop. Don't install anything.

---

## Step 5 — Run the checks (30 min)

Open a terminal. Run these and record every answer in
[HARDWARE.md](HARDWARE.md).

### 5a. Identify the machine
```bash
sudo dmidecode -s system-product-name; lscpu | grep "Model name"; lspci | grep -Ei "vga|3d|network"
```
Tells you the exact `AN515-…` model, whether the iGPU is Intel or AMD, and your
Wi-Fi chipset.

### 5b. Nvidia alive
```bash
lsmod | grep -c nvidia && nvidia-smi
```
Want: a non-zero count and a table showing the RTX 3050. **If `nvidia-smi`
fails, stop and tell me** — everything downstream depends on this.

### 5c. Render offload works
```bash
vulkaninfo --summary | grep -A2 deviceName; __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo -B | grep "OpenGL renderer"
```
Want: both the iGPU and the RTX 3050 listed, and the second command naming the
NVIDIA GPU. That's the path games will take.

### 5d. gamescope
```bash
gamescope -- vkcube
```
Want: a spinning cube in a fullscreen window. **This is the check most likely to
fail on Nvidia.** If it does, note the exact error — we fall back to `cage` and
it doesn't block M1.

### 5e. DualSense over USB
Plug it in with a **data** cable (many are charge-only).
```bash
ls /dev/input/by-id/ | grep -i wireless; sudo evtest
```
Pick the DualSense in the list. Press buttons, move sticks, touch the touchpad,
tilt it. Want: events for all of it. Note how many separate devices appear —
there should be a main one, a touchpad one, and a motion sensor one.

### 5f. DualSense over Bluetooth
Unplug USB. Hold **Create + PS** until the light bar flashes fast.
```bash
bluetoothctl
```
then inside: `power on` → `scan on` → wait for `Wireless Controller` → `pair <MAC>` → `trust <MAC>` → `connect <MAC>` → `exit`

Re-run `evtest` and confirm you get the same devices wirelessly.

### 5g. Battery + lightbar
```bash
cat /sys/class/power_supply/ps-controller-battery-*/capacity
ls /sys/class/leds/ | grep -i playstation
```
Want: a percentage, and LED entries. These are what the menu reads.

### 5h. The one everyone skips
Now plug in the **SanDisk** (just as a data disk — we're not booting it yet).
```bash
lsusb -t | grep -i -A2 storage; systemctl suspend
```
Wait 10 seconds, wake it with the power button, then:
```bash
lsblk; dmesg | tail -30
```
**Want: the SanDisk still present with the same device name, no USB reset
errors.** If it vanished or renamed itself, Rest Mode needs a workaround —
note the bridge chip from `lsusb -t` and I'll add a quirk to the image.

---

## Step 6 — Report back

Fill in the table and checklist in [HARDWARE.md](HARDWARE.md) and tell me:

1. Anything that **failed**, with the exact error text.
2. The output of 5a (model, iGPU vendor, Wi-Fi chipset) — this determines which
   firmware and drivers go into the image.
3. Whether 5h survived suspend.

That's everything I need to finalise the image. Then you shut down, unplug the
live USB, and wait for a `.img.zst` to flash.

---

## What can go wrong, and what it means

| Symptom | Meaning | Blocks? |
|---|---|---|
| USB not in F12 list | BIOS: F12 menu off, Secure Boot on, or Fast Boot | **Yes** — fix before continuing |
| "Secure Boot violation" | Secure Boot still enabled | **Yes** |
| `nvidia-smi` fails | Driver/firmware problem on this model | **Yes** — tell me the error |
| `gamescope` fails | Known Nvidia roughness | No — we use `cage` |
| DualSense USB works, BT doesn't | Bluetooth firmware missing | No — fixable in the image |
| SanDisk vanishes after suspend | USB bridge drops off the bus | No — Rest Mode becomes hibernate-only |
| Machine won't boot with SSD attached later | Firmware boot-order quirk | No — F12 every time |

Nothing here touches Windows. If you get bored halfway, power off, unplug the
stick, and the laptop is exactly as it was.
