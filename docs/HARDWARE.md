# PENTA — Hardware notes

Fill in the `?` entries during **M0**. This file is the record of what's actually
true about *your* machine, as opposed to what the internet says about Nitro 5s
in general.

---

## Target: Acer Nitro 5 (RTX 3050 Laptop)

| Item | Value |
|---|---|
| Exact model string (`AN515-…`) | ? |
| CPU | ? (Intel 11th/12th gen or AMD Ryzen 5xxx — changes the iGPU driver) |
| iGPU | ? (`i915` or `amdgpu`) — **this is what the laptop panel is wired to** |
| dGPU | RTX 3050 Laptop (`nvidia`) |
| MUX switch present? | ? (most 3050 models: no) |
| RAM | ? |
| Wi-Fi/BT chipset (`lspci`/`lsusb`) | ? |
| BIOS version | ? |
| USB port used for the SSD | ? (prefer the 10 Gbps port) |

### Hybrid graphics — the thing to understand

On a non-MUX Nitro 5 the internal display is physically connected to the
**iGPU**. The Nvidia GPU renders and hands frames over. So:

- The compositor (gamescope) runs on the **iGPU**.
- Games are launched with **PRIME render offload** onto the Nvidia GPU
  (`__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia`, or
  `DRI_PRIME` for Vulkan).
- An external monitor on the HDMI port *may* be wired directly to the Nvidia
  GPU — worth testing, it's often the better-performing path.

If the machine *does* have a MUX, forcing discrete-only in BIOS makes everything
simpler and faster. Check BIOS → Advanced for a "Display Mode / GPU Mode" entry.

---

## BIOS setup (do this once, before M0)

Acer's firmware has three specific traps:

1. **F12 Boot Menu is off by default.**
   `F2` at power-on → **Main** → set `F12 Boot Menu` to **Enabled**.
   Without this there is no boot-device picker at all.

2. **You cannot disable Secure Boot without a Supervisor Password.**
   **Security** → `Set Supervisor Password` → set one (write it down).
   Then **Boot** → `Secure Boot` → **Disabled**.
   You may clear the password afterwards; Secure Boot stays off.
   *Secure Boot must be off for the unsigned Nvidia kernel modules to load.
   Signing them is an M5 item.*

3. **Internal NVMe may be in Intel RST/RAID mode.** Irrelevant here — PENTA
   never touches the internal disk — but it's why generic "dual-boot Linux on a
   Nitro 5" guides fail. Leave it exactly as Windows likes it.

Also worth setting:
- Disable **Fast Boot** if the USB device isn't detected reliably.
- Leave **Windows Boot Manager** as the default boot entry, so that with the SSD
  unplugged the machine behaves exactly as it does today.

### Booting PENTA
Power on → tap **F12** → select the SanDisk → PENTA.
Power on → do nothing → Windows.

That's the entire dual-boot mechanism. Nothing is installed to the internal
disk, so there is no procedure to undo.

---

## Storage: SanDisk 1 TB external SSD

| Item | Value |
|---|---|
| Model (Extreme / Extreme Pro / Portable?) | ? |
| USB generation | ? (Gen1 = 5 Gbps ≈ 500 MB/s, Gen2 = 10 Gbps ≈ 1000 MB/s) |
| Enclosure bridge chip | ? (`lsusb -t`) |
| UAS supported / stable? | ? |
| Survives suspend/resume? | ? ← **critical for Rest Mode** |

**This disk gets completely erased.** It currently holds a Kali dual-boot
install; back up anything on it before M1.

### Known risk: USB + suspend
Some USB-SATA/NVMe bridges drop off the bus across a suspend/resume cycle,
which for a *boot* device means a hard hang on resume. Test this explicitly in
M0. If it misbehaves, the levers are:
- `usb-storage.quirks=<vid>:<pid>:u` (disable UAS for that bridge)
- disable USB autosuspend for the port
- worst case: Rest Mode becomes hibernate-only (still fine, just slower resume)

---

## M0 verification log

Record results here.

```
Date:
Live image used:
Firmware saw the USB device:        [ ]
Reached graphical session:          [ ]
nvidia-smi works:                   [ ]
vulkaninfo --summary (dGPU listed): [ ]
gamescope -- vkcube:                [ ]
DualSense USB (evtest):             [ ]
DualSense Bluetooth:                [ ]
Controller battery reported:        [ ]
Gyro + touchpad evdev nodes:        [ ]
Suspend/resume with SSD attached:   [ ]
Notes:
```
