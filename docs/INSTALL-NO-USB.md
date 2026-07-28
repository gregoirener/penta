# Installing PENTA with no USB media

You have no USB stick, and the target machine's only drive is the one we want to
overwrite. That looks circular, and it isn't: **the machine already has a
working OS and a bootloader we can add to.**

The trick is to boot a live Linux **entirely into RAM**. Once it's in RAM,
nothing it needs is on the disk any more, so the disk can be wiped out from
under it — including the file the live system booted from.

```
Windows (running)
   └─ put a live ISO on C:\  and a GRUB entry on the ESP
        └─ reboot → GRUB → loop-mount the ISO → copytoram=y
             └─ live Linux, running from RAM, disk untouched and unneeded
                  └─ curl the PENTA image → dd → /dev/nvme0n1   (Windows dies here)
                       └─ reboot → PENTA
```

---

## STOP — do not start until both are true

1. **A PENTA image exists and you can download it.** Check for a
   `penta-*.img.zst` asset on the repo's releases. If there isn't one, this
   procedure ends with a laptop that boots nothing.
2. **Anything you care about on that laptop is backed up.** Step 5 destroys
   Windows, your files, and every partition on the drive. There is no undo and
   no recovery partition afterwards.

Your Windows licence is a digital entitlement tied to the motherboard, so you
can reinstall Windows later for free with Microsoft's media tool — but only the
licence comes back, not the files.

**Sequencing matters more than anything else here.** Steps 1–3 are reversible;
they only add a boot entry. Step 5 is not. Do not do step 3 on a day when you
need the laptop working.

---

## Step 1 — Download two files (in Windows)

1. **A live ISO.** Arch (`archlinux-x86_64.iso`, ~1.3 GB) from
   https://archlinux.org/download/ — chosen because archiso supports
   `copytoram`, which is the whole basis of this method, and it ships `curl`
   and `zstd`.
2. **GRUB for Windows** — [GRUB2Win](https://sourceforge.net/projects/grub2win/).
   It installs GRUB to the EFI partition and adds a firmware boot entry without
   touching the Windows bootloader.

Put the ISO at `C:\archlinux.iso` — exactly there, no subfolder, no spaces.

> **RAM check:** `copytoram` needs enough free RAM to hold the whole ISO plus
> the running system — roughly 4 GB free. Any Nitro 5 with 8 GB+ is fine.

---

## Step 2 — BIOS

Reboot, tap **F2**:

1. **Security** → `Set Supervisor Password` → set one, **write it down**
   (Acer refuses to let you change Secure Boot without it)
2. **Boot** → `Secure Boot` → **Disabled**
3. **Main** → `F12 Boot Menu` → **Enabled**
4. **F10** to save

Secure Boot must stay off — the Nvidia modules are unsigned.

---

## Step 3 — Add the GRUB entry

Install GRUB2Win, then add a custom menu entry with this body. Adjust
`(hd0,gpt3)` if your Windows partition isn't the third — GRUB2Win's menu editor
will show you the list, and you can also press `c` at the GRUB prompt and run
`ls` to see every partition.

```
menuentry "Arch ISO (RAM)" {
    insmod ntfs
    insmod loopback
    insmod part_gpt
    search --no-floppy --set=root --file /archlinux.iso
    loopback loop /archlinux.iso
    linux (loop)/arch/boot/x86_64/vmlinuz-linux \
        img_dev=/dev/nvme0n1p3 img_loop=/archlinux.iso \
        copytoram=y earlymodules=loop
    initrd (loop)/arch/boot/x86_64/initramfs-linux.img
}
```

`copytoram=y` is the load-bearing part. Without it the live system keeps reading
from `C:\archlinux.iso` and the install dies the moment we wipe the disk.

`img_dev` must name the **partition holding the ISO** (the Windows C: partition),
not the whole disk. If you're unsure, boot the entry and run `lsblk` — if it
came up, you got it right.

---

## Step 4 — Boot it and get online

Reboot → **F12** → GRUB → "Arch ISO (RAM)". Let it finish copying; it sits for
a minute or two on a mostly blank screen while the ISO loads into memory.

You land at a root prompt. Get networking up — **Ethernet is far easier**, plug
the laptop into the router and it should already work:

```bash
ping -c2 archlinux.org
```

Wi-Fi, if you must:

```bash
iwctl station wlan0 connect "YOUR_SSID"
```

Confirm the live system is genuinely in RAM before going any further:

```bash
findmnt / | grep -q "tmpfs\|ram" && echo "RAM: safe to wipe" || echo "STOP — not in RAM"
```

**If that says STOP, do not continue.** Go back and check `copytoram=y`.

---

## Step 5 — Write PENTA over the whole drive

This is the irreversible one.

Identify the target — it's the NVMe, almost certainly `/dev/nvme0n1`:

```bash
lsblk -d -o NAME,SIZE,MODEL
```

Then stream the image straight from the release onto it. Nothing is stored
first; the live system is in RAM and has no disk to store it on anyway:

```bash
curl -fL "PASTE_THE_RELEASE_URL_HERE" | zstd -dc | dd of=/dev/nvme0n1 bs=8M status=progress oflag=direct
```

When it finishes:

```bash
sync && reboot
```

Windows is gone as of the first byte written.

---

## Step 6 — First boot

Remove nothing, just let it boot. On the first start `systemd-repart` grows the
data partition to fill the drive and creates swap, which adds ~30 seconds. Then
the PENTA menu.

If you get a black screen instead, the first-boot self-check writes its results
to `/var/log/penta-selftest.log` — reboot and hold **Escape** during boot to
reach a console.

---

## If it goes wrong before step 5

Nothing has been destroyed. Remove the GRUB2Win entry from Windows, or in BIOS
set Windows Boot Manager as first in the boot order. You're back where you
started.

## If it goes wrong after step 5

The drive has PENTA on it, whether or not PENTA boots. You need external media
to recover — which is the argument for buying a USB stick tomorrow *before*
doing step 5, not after. A €8 16 GB stick turns every failure in this document
from "bricked until I buy a stick" into "reflash and try again".

---

## Alternative: netboot (no ISO on disk at all)

If GRUB2Win won't cooperate, the Nitro 5's firmware supports UEFI PXE. The Mac
can serve the installer over the LAN with `dnsmasq` in proxy-DHCP mode, so the
laptop netboots with nothing written to its disk beforehand. It's more setup on
the Mac and needs both machines on the same wired segment. Ask and I'll write it
up — the disk-based route above is more likely to work first try.
