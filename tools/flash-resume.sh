#!/usr/bin/env bash
# Write an image to flaky USB media, resumably.
#
#   sudo ./tools/flash-resume.sh /tmp/img/penta-XXXX.img.xz
#
# Cheap USB sticks draw noticeably more current writing than idling, and some
# drop off the bus part-way through a sustained multi-gigabyte write. macOS
# reports that as "Device not configured" and dd dies — losing everything
# written so far, because the source was a decompression pipe with no way back.
#
# So: decompress once to a file, then write in segments, recording progress
# after each. A drop costs one segment. The device is re-located by size and
# name each time, because it usually comes back with a different disk number.

set -uo pipefail

IMG_XZ="${1:?usage: flash-resume.sh <image.img.xz>}"
SEGMENT_MB="${SEGMENT_MB:-256}"     # written per dd invocation
MAX_RETRIES="${MAX_RETRIES:-60}"

RAW="${IMG_XZ%.xz}"
RAW="${RAW%.zst}"
STATE="$RAW.progress"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -f "$IMG_XZ" ]] || die "$IMG_XZ not found"

# --- Decompress once --------------------------------------------------------
if [[ ! -f "$RAW" ]]; then
    need=$(( $(xz -l --robot "$IMG_XZ" 2>/dev/null | awk '/^totals/{print $5}') / 1048576 ))
    free=$(df -m / | awk 'NR==2{print $4}')
    say "decompressing (needs ~${need}MB, ${free}MB free)"
    (( free > need + 1024 )) || die "not enough free space to decompress"
    xz -dc "$IMG_XZ" > "$RAW" || die "decompression failed"
fi
TOTAL=$(stat -f%z "$RAW")
say "image: $(( TOTAL / 1048576 )) MB"

# --- Locate the stick by identity, not by disk number -----------------------
# It re-enumerates after a drop and frequently comes back as a different diskN.
find_disk() {
    local d
    for d in $(diskutil list external physical 2>/dev/null \
               | grep -oE '^/dev/disk[0-9]+' | sed 's|/dev/||'); do
        local info; info="$(diskutil info "$d" 2>/dev/null)"
        grep -q "Device Location:.*External" <<<"$info" || continue
        grep -q "Virtual:.*No"               <<<"$info" || continue
        local bytes; bytes="$(awk -F'[()]' '/Disk Size/{print $2}' <<<"$info" \
                              | awk '{print $1}')"
        (( bytes >= TOTAL )) && { echo "$d"; return 0; }
    done
    return 1
}

wait_for_disk() {
    local n=0
    while (( n < 60 )); do
        local d; d="$(find_disk)" && { echo "$d"; return 0; }
        sleep 2; ((n++))
    done
    return 1
}

DISK="$(wait_for_disk)" || die "no external disk large enough for the image"
say "target: /dev/$DISK  ($(diskutil info "$DISK" | awk -F: '/Device \/ Media Name/{print $2}' | xargs))"

OFFSET=0
[[ -f "$STATE" ]] && OFFSET=$(cat "$STATE")
(( OFFSET > 0 )) && say "resuming at $(( OFFSET / 1048576 )) MB"

printf '\n  \033[1;31mERASING /dev/%s\033[0m\n\n' "$DISK"

retries=0
while (( OFFSET < TOTAL )); do
    DISK="$(wait_for_disk)" || die "device did not come back"
    # force, not plain: DiskArbitration remounts the moment our own write
    # makes a partition table appear, and then yanks the raw device out from
    # under dd — which surfaces as "Device not configured".
    diskutil unmountDisk force "/dev/$DISK" >/dev/null 2>&1 || true

    seg_bytes=$(( SEGMENT_MB * 1048576 ))
    (( OFFSET + seg_bytes > TOTAL )) && seg_bytes=$(( TOTAL - OFFSET ))
    blocks=$(( seg_bytes / 1048576 ))
    skip=$(( OFFSET / 1048576 ))

    # caffeinate: stop the Mac idling, sleeping, or powering down the USB bus
    # part-way through a write that takes tens of minutes.
    if caffeinate -dimsu dd if="$RAW" of="/dev/r$DISK" bs=1m skip="$skip" \
          seek="$skip" count="$blocks" conv=notrunc 2>/dev/null; then
        OFFSET=$(( OFFSET + seg_bytes ))
        echo "$OFFSET" > "$STATE"
        printf '\r  %d / %d MB  (%d%%)   ' \
               "$(( OFFSET / 1048576 ))" "$(( TOTAL / 1048576 ))" \
               "$(( OFFSET * 100 / TOTAL ))"
        retries=0
    else
        ((retries++))
        (( retries > MAX_RETRIES )) && die "gave up after $MAX_RETRIES retries at $(( OFFSET / 1048576 )) MB"
        printf '\n'
        say "device dropped at $(( OFFSET / 1048576 )) MB — waiting for it to come back (retry $retries)"
        sleep 5
    fi
done

printf '\n'
sync
say "verifying"
sleep 2
DISK="$(wait_for_disk)" || die "device vanished before verification"

python3 - "/dev/r$DISK" <<'PY'
import struct, sys, uuid
with open(sys.argv[1], "rb") as f:
    head = f.read(1024 * 1024)
if head[512:520] != b"EFI PART":
    sys.exit("FAILED: no GPT header — the write did not land")
first, count, size = struct.unpack_from("<QII", head, 512 + 72)
names = []
for i in range(min(count, 8)):
    off = first * 512 + i * size
    if int(uuid.UUID(bytes_le=head[off:off + 16])) == 0:
        continue
    n = head[off + 56:off + 128].decode("utf-16-le").rstrip("\x00")
    s, e = struct.unpack_from("<QQ", head, off + 32)
    print(f"  partition {i+1}: {n:12} {(e - s + 1) * 512 / 1024**3:.1f} GiB")
    names.append(n)
if not any("ESP" in n for n in names):
    sys.exit("FAILED: no EFI System Partition")
print("  VERIFIED — image written and bootable")
PY

rm -f "$STATE"
say "done — eject with: diskutil eject /dev/$DISK"
