# Installing PENTA with no USB media

You have no USB stick, and the target machine's only drive is the one we want to
overwrite. That looks circular, and it isn't: **the machine already has a
working OS and a bootloader we can add to.**

The trick is to boot a live Linux **entirely into RAM**. Once it's in RAM,
nothing it needs is on the disk any more, so the disk can be wiped out from
under it — including the file the live system booted from.

```
Windows (running)
   └─ put the live ISO AND the PENTA image on C:\, add a GRUB entry
        └─ reboot → GRUB → loop-mount the ISO → copytoram=y
             └─ live Linux, running from RAM
                  └─ copy the PENTA image off C:\ into RAM too
                       └─ dd from RAM → /dev/nvme0n1   (Windows dies here)
                            └─ reboot → PENTA
```

**No network is needed on the target machine at all.** Everything is downloaded
in Windows, where Wi-Fi and a browser already work. Both files ride along on the
disk, and both end up in RAM before anything is overwritten.

> **Why no Windows app can do this for you:** Rufus, Etcher and Ventoy all write
> to a *different* device than the one Windows booted from — Windows holds an
> exclusive lock on its own system disk. Nothing running inside Windows can
> overwrite the disk Windows is running on. Hence the RAM boot.

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

## Step 1 — Download three things (in Windows)

1. **The PENTA image.** From the repo's Actions run, download the
   `penta-image` artifact (a zip, ~494 MB), extract it, and put the
   `penta-*.img.zst` inside at **`C:\penta.img.zst`**.
   A browser signed into GitHub can fetch it from the private repo directly —
   no token juggling, and this is the only download that has to happen at all.
2. **A live ISO.** Arch (`archlinux-x86_64.iso`, ~1.3 GB) from
   https://archlinux.org/download/ — chosen because archiso supports
   `copytoram`, which is the whole basis of this method. Put it at
   **`C:\archlinux.iso`** — exactly there, no subfolder, no spaces.
3. **GRUB for Windows** — [GRUB2Win](https://sourceforge.net/projects/grub2win/).
   It installs GRUB to the EFI partition and adds a firmware boot entry without
   touching the Windows bootloader.

> **RAM check.** Everything has to fit in memory at once: the ISO (~1.3 GB), the
> live system (~1 GB) and the PENTA image (~0.5 GB) — call it 3.5 GB, so you
> want 6 GB+ free. Fine on any 8 GB Nitro 5, comfortable on 16 GB.
> If the machine has only 8 GB, close Windows apps before rebooting; the check
> in step 5 will catch a shortfall before anything is destroyed.

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

**Why GRUB and not systemd-boot.** systemd-boot can only read files from the EFI
System Partition, and a Windows ESP is typically 100 MB with ~30 MB free — the
Arch initramfs alone is ~130 MB. GRUB's EFI binary is a few MB and can read
NTFS, so the kernel and initrd stay on `C:\` where there is room. This is the
whole reason GRUB2Win exists.

Install GRUB2Win → **Manage Boot Menu** → add an entry of type **Custom code**,
name it `Arch RAM`, and paste this as the body:

```
insmod ntfs
insmod loopback
insmod part_gpt
search --no-floppy --set=root --file /archlinux.iso
loopback loop /archlinux.iso
linux (loop)/arch/boot/x86_64/vmlinuz-linux img_dev=/dev/nvme0n1p3 img_loop=/archlinux.iso copytoram=y earlymodules=loop
initrd (loop)/arch/boot/x86_64/initramfs-linux.img
```

`search --file /archlinux.iso` locates whichever partition actually holds the
ISO, so only `img_dev=` carries a guess. If the live system cannot find the ISO,
that number is what to change — `lsblk -f` at the GRUB rescue prompt or in any
live shell will show you the right one.

`copytoram=y` is the load-bearing part. Without it the live system keeps reading
from `C:\archlinux.iso` and the install dies the moment we wipe the disk.

`img_dev` must name the **partition holding the ISO** (the Windows C: partition),
not the whole disk. If you're unsure, boot the entry and run `lsblk` — if it
came up, you got it right.

---

## Step 4 — Boot it

Reboot → **F12** → GRUB → "Arch ISO (RAM)". Let it finish copying; it sits for
a minute or two on a mostly blank screen while the ISO loads into memory.

You land at a root prompt. **No networking needed** — both files are already on
the disk.

Confirm the live system is genuinely in RAM before going any further:

```bash
findmnt -n -o SOURCE / ; free -h
```

The root source should be a `tmpfs`/`ram` device, not a partition.

**If root is still on a partition, stop.** Go back and check `copytoram=y` —
without it, wiping the disk kills the running system mid-write.

---

## Step 5 — Pull the image into RAM

**This is the step that makes the whole thing safe.** The image currently lives
on the disk we are about to destroy, so it has to move into memory first.

Find and mount the Windows partition read-only:

```bash
lsblk -f
mkdir -p /mnt/win
mount -o ro /dev/nvme0n1p3 /mnt/win      # adjust pN to your C: partition
ls -lh /mnt/win/penta.img.zst
```

Copy it into RAM and unmount:

```bash
cp /mnt/win/penta.img.zst /tmp/
umount /mnt/win
ls -lh /tmp/penta.img.zst
```

Now verify **nothing** is still reading from the disk:

```bash
findmnt | grep nvme || echo "nothing mounted from the NVMe — safe to wipe"
```

**If that lists any mount on the NVMe, stop and unmount it.** Writing over a
mounted filesystem corrupts the write and can hang the machine mid-flash.

---

## Step 6 — Write PENTA over the whole drive

This is the irreversible one. Windows dies at the first byte.

Confirm the target really is the internal drive:

```bash
lsblk -d -o NAME,SIZE,MODEL
```

Then write it, straight from RAM:

```bash
zstd -dc /tmp/penta.img.zst | dd of=/dev/nvme0n1 bs=8M status=progress oflag=direct
sync
```

Roughly 25 GB decompressed to NVMe — a couple of minutes. Then:

```bash
reboot
```

---

## Step 7 — First boot

Remove nothing, just let it boot. On the first start `systemd-repart` grows the
data partition to fill the drive and creates swap, which adds ~30 seconds. Then
the PENTA menu.

If you get a black screen instead, the first-boot self-check writes its results
to `/var/log/penta-selftest.log` — reboot and hold **Escape** during boot to
reach a console.

---

## If it goes wrong before step 6

Nothing has been destroyed. Reboot, pick Windows Boot Manager, and remove the
GRUB2Win entry. You're back where you started — the only changes were two files
on C:\ and a boot entry.

## If it goes wrong after step 6

The drive has PENTA on it, whether or not PENTA boots. You need external media
to recover — which is the argument for buying a USB stick tomorrow *before*
doing step 6, not after. A €8 16 GB stick turns every failure in this document
from "bricked until I buy a stick" into "reflash and try again".

---

## Alternative: netboot (no ISO on disk at all)

If GRUB2Win won't cooperate, the Nitro 5's firmware supports UEFI PXE. The Mac
can serve the installer over the LAN with `dnsmasq` in proxy-DHCP mode, so the
laptop netboots with nothing written to its disk beforehand. It's more setup on
the Mac and needs both machines on the same wired segment. Ask and I'll write it
up — the disk-based route above is more likely to work first try.
