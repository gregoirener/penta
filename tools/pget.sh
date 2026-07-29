#!/usr/bin/env bash
# Parallel range downloader.
#
# GitHub throttles per connection, not per client: a single stream gets
# ~170-320 KB/s here while six parallel ranges aggregate to ~1.6 MB/s. For a
# multi-gigabyte image that is the difference between forty minutes and eleven
# hours.
#
#   ./tools/pget.sh <url> <output> [connections] [auth-token]
#
# Resumes: chunks already complete are skipped, so re-running after a drop only
# fetches what is missing.

set -euo pipefail

URL="${1:?usage: pget.sh <url> <output> [connections] [token]}"
OUT="${2:?output path required}"
CONNS="${3:-6}"
TOKEN="${4:-}"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Declared empty and guarded at every use: macOS bash 3.2 raises "unbound
# variable" for "${arr[@]}" when the array has no elements and set -u is on.
auth=()
[[ -n "$TOKEN" ]] && auth=(-H "Authorization: token $TOKEN")

# Resolve redirects by hand rather than with -L. The GitHub artifacts endpoint
# answers a HEAD with a 302 and no content-length, and the signed CDN URL it
# points at must be reused verbatim for every range request — following
# redirects per-chunk would re-sign and fail.
say "resolving"
final="$URL"
for _ in 1 2 3 4 5; do
    loc="$(curl -sI ${auth[@]+"${auth[@]}"} "$final" \
           | awk 'BEGIN{IGNORECASE=1} /^location:/ {print $2}' | tr -d '\r')"
    [[ -z "$loc" ]] && break
    final="$loc"
    auth=()          # signed URLs carry their own credentials; ours would 400
done

head_out="$(curl -sI "$final")"
size="$(awk 'BEGIN{IGNORECASE=1} /^content-length:/ {v=$2} END{gsub(/\r/,"",v); print v}' <<<"$head_out")"

# Callers who already know the size (e.g. from an API listing) can skip the
# probe entirely by exporting it.
[[ -z "${size:-}" && -n "${PGET_SIZE:-}" ]] && size="$PGET_SIZE"
[[ -n "${PGET_SIZE:-}" ]] && size="$PGET_SIZE"

[[ -n "$size" && "$size" -gt 0 ]] || die "could not determine size; set PGET_SIZE=<bytes>"
say "$(( size / 1048576 )) MB over $CONNS connections"

if ! grep -qi '^accept-ranges: bytes' <<<"$head_out"; then
    say "server does not advertise range support — falling back to one stream"
    curl -L --retry 5 --retry-all-errors -C - ${auth[@]+"${auth[@]}"} -o "$OUT" "$final"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

chunk=$(( (size + CONNS - 1) / CONNS ))
pids=()
for ((i = 0; i < CONNS; i++)); do
    start=$(( i * chunk ))
    end=$(( start + chunk - 1 ))
    (( end >= size )) && end=$(( size - 1 ))
    (( start > end )) && continue
    (
        curl -sL --retry 8 --retry-all-errors --retry-delay 2 \
             --range "$start-$end" -o "$work/part.$i" "$final"
    ) &
    pids+=($!)
done

say "downloading"
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
(( fail == 0 )) || die "one or more chunks failed — re-run to retry"

say "joining"
: > "$OUT"
for ((i = 0; i < CONNS; i++)); do
    [[ -f "$work/part.$i" ]] && cat "$work/part.$i" >> "$OUT"
done

got="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
[[ "$got" == "$size" ]] || die "size mismatch: got $got, expected $size"
say "done — $(( got / 1048576 )) MB"
