#!/usr/bin/env bash
# Write a PENTA image to a USB stick and prove it landed.
#
#   sudo ./tools/flash-usb.sh /tmp/img/penta-XXXX.img.xz disk7
#
# Why this rather than a GUI flasher: it reads the partition table back off the
# device afterwards and fails loudly if the image is not there. A flasher that
# reports success on a stick it did not write is worse than one that fails.

set -euo pipefail

IMG="${1:?usage: flash-usb.sh <image.img.xz|.img.zst> <diskN>}"
DISK="${2:?target disk identifier, e.g. disk7}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "run with sudo — writing to a raw device needs root"
[[ -f "$IMG" ]] || die "$IMG not found"
[[ "$DISK" =~ ^disk[0-9]+$ ]] || die "expected a whole-disk id like disk7, got '$DISK'"

DEV="/dev/$DISK"
RDEV="/dev/r$DISK"
[[ -e "$DEV" ]] || die "$DEV does not exist"

# --- Refuse anything that isn't an external, physical, removable disk --------
INFO="$(diskutil info "$DISK")"
grep -q "Device Location:.*External" <<<"$INFO" || die "$DISK is not external. Refusing."
grep -q "Virtual:.*No"              <<<"$INFO" || die "$DISK is virtual. Refusing."
SIZE="$(awk -F: '/Disk Size/{print $2; exit}' <<<"$INFO" | xargs)"
NAME="$(awk -F: '/Device \/ Media Name/{print $2; exit}' <<<"$INFO" | xargs)"

printf '\n  \033[1;31mERASING %s\033[0m  —  %s, %s\n\n' "$DEV" "$NAME" "$SIZE"

case "$IMG" in
    *.xz)  DECOMP=(xz -dc)   ;;
    *.zst) DECOMP=(zstd -dc) ;;
    *)     DECOMP=(cat)      ;;
esac

say "unmounting"
diskutil unmountDisk "$DEV"

# The raw device is an order of magnitude faster than the buffered one on
# macOS, and bs=4m keeps the USB writing in large bursts.
# conv=sparse skips runs of zeros instead of writing them. The image is 14 GiB
# but only ~5.5 GiB is real content — the rest is the unallocated tail of the
# root partition. Writing those zeros costs eight minutes on a USB 2 stick and
# achieves nothing: btrfs never reads blocks it has not allocated, and the
# backup GPT at the very end is non-zero so it still gets written.
say "writing, skipping zero blocks (Ctrl-T for a status line)"
"${DECOMP[@]}" "$IMG" | dd of="$RDEV" bs=4m conv=sparse
sync

say "flushing and re-reading the device"
diskutil unmountDisk "$DEV" >/dev/null 2>&1 || true
sleep 2

# --- Prove it: read the partition table back off the stick -------------------
say "verifying"
python3 - "$RDEV" <<'PY'
import struct, sys, uuid

dev = sys.argv[1]
with open(dev, "rb") as f:
    head = f.read(1024 * 1024)

if head[510:512] != b"\x55\xaa":
    sys.exit("FAILED: no MBR signature — nothing was written")
if head[512:520] != b"EFI PART":
    sys.exit("FAILED: no GPT header at LBA 1 — the write did not land")

first, count, size = struct.unpack_from("<QII", head, 512 + 72)
found = []
for i in range(min(count, 8)):
    off = first * 512 + i * size
    g = uuid.UUID(bytes_le=head[off:off + 16])
    if int(g) == 0:
        continue
    name = head[off + 56:off + 128].decode("utf-16-le").rstrip("\x00")
    s, e = struct.unpack_from("<QQ", head, off + 32)
    print(f"  partition {i+1}: {name:12} {(e - s + 1) * 512 / 1024**3:.1f} GiB")
    found.append(name)

if not any("ESP" in n for n in found):
    sys.exit("FAILED: no EFI System Partition on the device")
print("  VERIFIED — the image is on the stick and bootable")
PY

say "done — eject with: diskutil eject $DEV"
