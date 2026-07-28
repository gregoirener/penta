#!/usr/bin/env bash
# Stream a PENTA image from a GitHub release straight onto an external SSD.
# Nothing is stored on the Mac — the image is decompressed in a pipe.
#
#   ./tools/flash.sh disk6                 # latest release
#   ./tools/flash.sh disk6 v0.3.0          # a specific tag
#   PENTA_IMAGE=./local.img.zst ./tools/flash.sh disk6
#
# DESTRUCTIVE. It will make you confirm.

set -euo pipefail

REPO="${PENTA_REPO:-gregoirener/penta}"
DISK="${1:-}"
TAG="${2:-latest}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[[ -n "$DISK" ]] || die "usage: $0 <diskN> [tag]   (see: diskutil list external physical)"
[[ "$DISK" =~ ^disk[0-9]+$ ]] || die "expected a whole-disk identifier like 'disk6', got '$DISK'"
command -v zstd >/dev/null || die "zstd not found — brew install zstd"

DEV="/dev/$DISK"
RDEV="/dev/r$DISK"          # raw device: dramatically faster on macOS
[[ -e "$DEV" ]] || die "$DEV does not exist"

# --- Refuse to touch anything internal ---------------------------------------
INFO="$(diskutil info "$DISK")"
grep -q "Device Location:.*External" <<<"$INFO" \
  || die "$DISK is not an external disk. Refusing."
grep -q "Virtual:.*No" <<<"$INFO" \
  || die "$DISK looks virtual (a disk image?). Refusing."

SIZE="$(awk -F: '/Disk Size/{print $2; exit}' <<<"$INFO" | xargs)"
NAME="$(awk -F: '/Device \/ Media Name/{print $2; exit}' <<<"$INFO" | xargs)"

# --- Show the user exactly what dies -----------------------------------------
printf '\n  \033[1;31mTHIS ERASES THE ENTIRE DISK\033[0m\n\n'
printf '    Device : %s\n    Media  : %s\n    Size   : %s\n\n' "$DEV" "$NAME" "$SIZE"
diskutil list "$DISK"
printf '\n'
printf 'Type \033[1m%s\033[0m to confirm, anything else to abort: ' "$DISK"
read -r CONFIRM
[[ "$CONFIRM" == "$DISK" ]] || die "aborted"

# --- Resolve the image source ------------------------------------------------
if [[ -n "${PENTA_IMAGE:-}" ]]; then
  [[ -f "$PENTA_IMAGE" ]] || die "PENTA_IMAGE=$PENTA_IMAGE not found"
  SRC_CMD=(cat "$PENTA_IMAGE")
  say "source: local file $PENTA_IMAGE"
else
  command -v gh >/dev/null || die "gh not found (brew install gh), or set PENTA_IMAGE=<file>"
  say "resolving release '$TAG' from $REPO"
  URL="$(gh release view "$TAG" --repo "$REPO" --json assets \
         --jq '.assets[] | select(.name | endswith(".img.zst")) | .url' | head -1)"
  [[ -n "$URL" ]] || die "no .img.zst asset on release '$TAG'"
  SRC_CMD=(curl -fL --retry 3 --retry-delay 2 "$URL")
  say "source: $URL"
fi

# --- Unmount (not eject — we still need the device node) ---------------------
say "unmounting $DISK"
diskutil unmountDisk "$DEV"

# --- Stream: download -> decompress -> raw device ----------------------------
say "writing to $RDEV (Ctrl-T for progress if pv is missing)"
if command -v pv >/dev/null; then
  "${SRC_CMD[@]}" | pv -N image | zstd -dc | sudo dd of="$RDEV" bs=4m
else
  "${SRC_CMD[@]}" | zstd -dc | sudo dd of="$RDEV" bs=4m
fi

sync
say "done — the GPT and data partition are repaired on first boot"
say "next: diskutil eject $DISK, plug into the Nitro 5, tap F12"
