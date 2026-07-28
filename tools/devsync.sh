#!/usr/bin/env bash
# Push a menu build to the running console and restart it.
#
#   ./tools/devsync.sh penta.local
#   ./tools/devsync.sh 192.168.1.42
#
# The OS image almost never changes; the menu changes constantly. This is the
# loop you'll actually live in — expect ~2 seconds end to end.

set -euo pipefail

HOST="${1:-penta.local}"
# `penta` has no shell by design; the dev loop goes in as root by key.
USER="${PENTA_USER:-root}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/penta-menu.x86_64"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[[ -x "$GODOT" ]] || die "Godot not found at $GODOT (set GODOT=…)"

say "exporting menu for linuxbsd/x86_64"
mkdir -p "$ROOT/build"
"$GODOT" --headless --path "$ROOT/menu" --export-release "Linux x86_64" "$OUT" \
  || die "export failed — create a 'Linux x86_64' export preset in the Godot editor first"

say "syncing to $USER@$HOST"
rsync -az --info=stats1 "$OUT" "$USER@$HOST:/opt/penta/penta-menu"

say "restarting the session"
# greetd owns the session; restarting it relaunches gamescope + the menu.
ssh "$USER@$HOST" 'systemctl restart greetd.service'

say "done"
