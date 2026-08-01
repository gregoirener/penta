#!/usr/bin/env bash
# Build a complete PENTA install stick on a Mac, in one command.
#
#   ./tools/make-installer-stick.sh disk4
#
# Run it as YOURSELF, not under sudo. It asks for your password once, when it
# reaches the raw write. Running the whole thing as root breaks `gh`: sudo
# resets HOME, so the GitHub token in ~/.config/gh is invisible and the very
# first release lookup fails with an authentication error.
#
# Produces a stick that boots the PENTA installer with the console image
# sitting on it, compressed, ready to be written to an internal disk. The stick
# never runs PENTA — it runs an installer, and PENTA is only ever decompressed
# onto the target NVMe.
#
#   ┌─ PENTA_IESP     512 MiB  the installer's bootloader
#   ├─ PENTA_INST       3 GiB  the installer OS  (~1 GB used)
#   └─ PENTA_IMG        6 GiB  penta-<sha>.img.xz lives here, compressed
#
# Nothing is stored on the Mac. Both downloads are streamed — the installer
# straight to the raw device, the console image straight onto the stick's
# payload volume — because this Mac has under 8 GB free and the two files come
# to ~2.4 GB. That is also why there is no "download then flash" mode.

set -euo pipefail

REPO="${PENTA_REPO:-gregoirener/penta}"
DISK="${1:-}"
IMAGE_TAG="${2:-latest}"

# 8 GB, decimal. The partition layout above needs 9.5 GiB, so this is the
# smallest stick that can physically hold it.
MIN_STICK=$((8 * 1000 * 1000 * 1000))
# PAYLOAD_VOL is discovered at runtime — see step 2. A FAT32 label is capped at
# 11 characters, so it cannot be predicted from the name we asked for.

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

[[ -n "$DISK" ]] || die "usage: $0 <diskN> [console-image-tag]
       see: diskutil list external physical"
[[ "$DISK" =~ ^disk[0-9]+$ ]] || die "expected a whole-disk id like 'disk4', got '$DISK'"

# Deliberately NOT `[[ $EUID -eq 0 ]]`. Only the dd needs root, and it gets it
# on its own line below. Requiring root for the whole script means gh runs with
# HOME=/var/root and cannot see your login.
if [[ $EUID -eq 0 ]]; then
  die "do not run this under sudo — run it as yourself.
       gh keeps its token in \$HOME/.config/gh, and sudo resets HOME, so every
       release lookup would fail. The one command that needs root asks for your
       password when it gets there."
fi
command -v gh >/dev/null || die "gh not found — brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in — run: gh auth login"
command -v xz >/dev/null || die "xz not found — brew install xz"

DEV="/dev/$DISK"
RDEV="/dev/r$DISK"          # raw device: an order of magnitude faster on macOS
[[ -e "$DEV" ]] || die "$DEV does not exist"

# --- Refuse anything that is not an external physical disk --------------------
INFO="$(diskutil info "$DISK")"
grep -q "Device Location:.*External" <<<"$INFO" || die "$DISK is not external. Refusing."
grep -q "Virtual:.*No"              <<<"$INFO" || die "$DISK is virtual. Refusing."

STICK_BYTES="$(awk -F'[()]' '/Disk Size/{print $2; exit}' <<<"$INFO" | awk '{print $1}')"
SIZE_H="$(awk -F: '/Disk Size/{print $2; exit}' <<<"$INFO" | xargs)"
NAME="$(awk -F: '/Device \/ Media Name/{print $2; exit}' <<<"$INFO" | xargs)"

if [[ "${STICK_BYTES:-0}" =~ ^[0-9]+$ ]] && (( STICK_BYTES < MIN_STICK )); then
  die "$DISK is $SIZE_H — the installer layout needs 9.5 GiB, so 8 GB minimum"
fi

# --- Resolve both assets before destroying anything ---------------------------
# Doing this first means a missing release is a message, not a wiped stick.
say "resolving the installer from $REPO"
INST_TAG="$(gh release list --repo "$REPO" --limit 30 \
            --json tagName -q '.[] | select(.tagName | startswith("installer-")) | .tagName' \
            | head -1)"
[[ -n "$INST_TAG" ]] || die "no 'installer-*' release found.
       Run the 'build installer' workflow first:
         gh workflow run installer.yml --repo $REPO"

INST_NAME="$(gh release view "$INST_TAG" --repo "$REPO" --json assets \
             -q '.assets[] | select(.name | endswith(".img.xz")) | .name' | head -1)"
[[ -n "$INST_NAME" ]] || die "release $INST_TAG has no .img.xz asset"
say "  installer: $INST_TAG / $INST_NAME"

say "resolving the console image ($IMAGE_TAG)"
if [[ "$IMAGE_TAG" == "latest" ]]; then
  IMAGE_TAG="$(gh release list --repo "$REPO" --limit 30 --json tagName \
               -q '.[] | select(.tagName | startswith("build-")) | .tagName' | head -1)"
fi
[[ -n "$IMAGE_TAG" ]] || die "no 'build-*' console image release found"

IMG_NAME="$(gh release view "$IMAGE_TAG" --repo "$REPO" --json assets \
            -q '.assets[] | select(.name | test("^penta-[0-9a-f]+\\.img\\.(xz|zst)$")) | .name' | head -1)"
[[ -n "$IMG_NAME" ]] || die "release $IMAGE_TAG has no penta-*.img.xz asset"
say "  console:   $IMAGE_TAG / $IMG_NAME"

# --- Confirm ------------------------------------------------------------------
printf '\n  \033[1;31mTHIS ERASES %s COMPLETELY\033[0m\n\n' "$DEV"
printf '    Media : %s\n    Size  : %s\n\n' "$NAME" "$SIZE_H"
diskutil list "$DISK" || true
printf '\nType \033[1m%s\033[0m to confirm, anything else to abort: ' "$DISK"
read -r CONFIRM
[[ "$CONFIRM" == "$DISK" ]] || die "aborted — nothing was written"

# --- 1. Installer image, streamed to the raw device ---------------------------
say "unmounting $DISK"
diskutil unmountDisk "$DEV"

say "writing the installer (streamed; nothing lands on this Mac)"
say "    macOS will ask for your password — the raw device needs root"
# conv=sparse skips runs of zeros. The 6 GiB payload partition is empty, so
# this is the difference between writing 9.5 GiB and writing ~1 GB.
#
# `gh release download`, not curl. This repo is private, so a plain curl of the
# browser download URL comes back 404 — GitHub hides private assets rather than
# returning 401. gh carries the token (which lives in the login keyring here,
# not in a file), so it just works, and there is no auth header to get wrong.
#
# sudo on the dd alone, so gh keeps running as you.
if command -v pv >/dev/null; then
  gh release download "$INST_TAG" --repo "$REPO" --pattern "$INST_NAME" --output - \
    | pv -N installer | xz -dc | sudo dd of="$RDEV" bs=4m conv=sparse
else
  warn "pv not installed (brew install pv) — press Ctrl-T for progress"
  gh release download "$INST_TAG" --repo "$REPO" --pattern "$INST_NAME" --output - \
    | xz -dc | sudo dd of="$RDEV" bs=4m conv=sparse
fi
sync

# --- 2. Wait for the payload volume, and ask where it actually mounted --------
# NOT a hardcoded /Volumes/<label>. A FAT32 label is capped at 11 characters, so
# the volume can mount under a truncated name — PENTA_PAYLOAD became
# PENTA_PAYLO — and waiting for a path that will never exist looks exactly like
# a stick that failed to mount. The partition number is stable; the name is not.
PAYLOAD_PART="${DEV}s3"

# macOS re-reads the partition table on its own after a raw write, but takes its
# time about it — measured at over 90 seconds on this machine. A 30s wait gave
# up while the kernel was still working and reported a stick that had, in fact,
# been written perfectly. Wait for the device NODE first, separately, so the
# two failure modes ("never re-read" and "read but would not mount") stay
# distinguishable.
say "waiting for macOS to re-read the partition table"
for i in $(seq 1 120); do
  [[ -e "$PAYLOAD_PART" ]] && break
  # Nudge it: reading the whole disk makes DiskArbitration re-probe.
  (( i % 10 == 0 )) && diskutil list "$DEV" >/dev/null 2>&1
  sleep 1
done
[[ -e "$PAYLOAD_PART" ]] || die "$PAYLOAD_PART never appeared after two minutes.
       The image was written, but macOS has not re-read the partition table.
       Unplug the stick, plug it back in, and re-run — the write is idempotent."
say "  $PAYLOAD_PART is there"

say "mounting the payload partition"
PAYLOAD_VOL=""
for _ in $(seq 1 60); do
  diskutil mount "$PAYLOAD_PART" >/dev/null 2>&1 || true
  PAYLOAD_VOL="$(diskutil info "$PAYLOAD_PART" 2>/dev/null \
                 | awk -F': *' '/Mount Point/{print $2; exit}' | xargs || true)"
  [[ -n "$PAYLOAD_VOL" && -d "$PAYLOAD_VOL" ]] && break
  PAYLOAD_VOL=""
  sleep 1
done

# Last resort: find it by the marker file the build drops on that partition.
# Works whatever the volume ended up being called.
if [[ -z "$PAYLOAD_VOL" ]]; then
  for v in /Volumes/*; do
    [[ -f "$v/PUT-PENTA-IMAGE-HERE.txt" ]] && { PAYLOAD_VOL="$v"; break; }
  done
fi

if [[ -z "$PAYLOAD_VOL" ]]; then
  warn "could not mount $PAYLOAD_PART. Current state:"
  diskutil list "$DEV" >&2 || true
  die "the stick is written and bootable, but the console image is not on it.
       Open it in Finder and copy $IMG_NAME onto the PENTA_IMG volume by hand,
       or unplug/replug the stick and re-run this script."
fi
say "  mounted at $PAYLOAD_VOL"

# --- 3. Console image, streamed onto the stick --------------------------------
say "downloading the console image straight onto the stick (~2 GB)"
if command -v pv >/dev/null; then
  gh release download "$IMAGE_TAG" --repo "$REPO" --pattern "$IMG_NAME" --output - \
    | pv -N "$IMG_NAME" > "$PAYLOAD_VOL/$IMG_NAME"
else
  gh release download "$IMAGE_TAG" --repo "$REPO" --pattern "$IMG_NAME" \
    --output "$PAYLOAD_VOL/$IMG_NAME" --clobber
fi

# The most likely failure here is a FAT32 write that ran out of room, and a
# truncated payload fails hours later mid-install. Check it now.
WROTE=$(stat -f%z "$PAYLOAD_VOL/$IMG_NAME" 2>/dev/null || echo 0)
EXPECT=$(gh release view "$IMAGE_TAG" --repo "$REPO" --json assets \
         -q ".assets[] | select(.name == \"$IMG_NAME\") | .size" | head -1)
if [[ "${EXPECT:-0}" =~ ^[0-9]+$ ]] && (( WROTE != EXPECT )); then
  die "payload is $WROTE bytes, expected $EXPECT — the copy is incomplete"
fi
say "payload verified: $((WROTE / 1000000)) MB"

sync
say "ejecting"
diskutil eject "$DEV" || warn "could not eject — do it from Finder"

printf '\n  \033[32mDone.\033[0m The stick boots the PENTA installer.\n'
cat <<EOF

    1. Plug it into the Nitro 5 and tap F12 at power-on
    2. Pick the USB device
    3. The installer lists the disks — choose the NVMe and type ERASE NVME0N1
    4. When it finishes, remove the stick and reboot

  PENTA is decompressed onto the NVMe during step 3. It is never unpacked on
  the stick, and the stick is not needed again afterwards — the installer
  registers PENTA in the firmware boot menu, so the machine boots it directly.

EOF
