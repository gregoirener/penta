#!/usr/bin/env bash
# Serve the PENTA image to the target machine over the LAN.
#
#   ./tools/serve-image.sh ~/Downloads/penta-image.zip
#   ./tools/serve-image.sh ~/Downloads/penta-abc1234.img.zst
#
# Why not curl straight from GitHub on the target: the repo is private, so both
# release and artifact URLs need a token — awkward to supply from a live system
# booted into RAM. Serving from the Mac needs no auth, and a LAN transfer is
# minutes rather than the 20 the internet leg takes.
#
# Read-only, one file, stops when you press Ctrl-C.

set -euo pipefail

SRC="${1:-}"
PORT="${PORT:-8000}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[[ -n "$SRC" ]] || die "usage: $0 <penta-image.zip | penta-*.img.zst>"
[[ -f "$SRC" ]] || die "$SRC not found"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# GitHub wraps artifacts in a zip; releases hand you the .img.zst directly.
if [[ "$SRC" == *.zip ]]; then
  say "unpacking artifact zip"
  unzip -q -o "$SRC" -d "$WORK"
  IMG="$(find "$WORK" -name '*.img.zst' | head -1)"
  [[ -n "$IMG" ]] || die "no .img.zst inside $SRC"
else
  IMG="$SRC"
fi

SERVE_DIR="$(cd "$(dirname "$IMG")" && pwd)"
NAME="$(basename "$IMG")"
SIZE="$(du -h "$IMG" | cut -f1)"

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
[[ -n "$IP" ]] || die "could not determine this Mac's LAN IP — is Wi-Fi on?"

cat <<EOF

  Serving  $NAME  ($SIZE)

  On the target machine, once it is running the live system in RAM
  (see docs/INSTALL-NO-USB.md), confirm the target disk first:

    lsblk -d -o NAME,SIZE,MODEL

  Then — THIS ERASES THE WHOLE DISK, Windows included:

    curl -fL http://$IP:$PORT/$NAME | zstd -dc | dd of=/dev/nvme0n1 bs=8M status=progress oflag=direct
    sync && reboot

  Ctrl-C here when it finishes.

EOF

cd "$SERVE_DIR"
say "listening on $IP:$PORT"
exec python3 -m http.server "$PORT" --bind 0.0.0.0
