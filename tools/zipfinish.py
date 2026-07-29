#!/usr/bin/env python3
"""Finish an interrupted zipget download.

GitHub signs artifact URLs for ten minutes. A multi-gigabyte parallel download
takes longer than that, so chunks still in flight when the signature expires
retry forever against a dead URL. The bytes already fetched are perfectly good;
only the tails are missing.

This re-signs, tops up the short chunks, then joins and inflates.

    ./tools/zipfinish.py <api-url> <tmpdir> <output> --start N --chunk N \\
                         --count N --size N [--method deflate|store] [--token T]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def resolve(url: str, token: str) -> str:
    """A fresh signed URL. Cheap, so do it right before each transfer."""
    final, tok = url, token
    for _ in range(5):
        head = subprocess.run(
            ["curl", "-sI"] + (["-H", f"Authorization: token {tok}"] if tok else [])
            + [final], capture_output=True, text=True).stdout
        loc = ""
        for line in head.splitlines():
            if line.lower().startswith("location:"):
                loc = line.split(":", 1)[1].strip()
        if not loc:
            break
        final, tok = loc, ""
    return final


def top_up(job) -> tuple[int, int]:
    i, path, want, start, end, api, token = job
    have = path.stat().st_size if path.exists() else 0
    if have >= want:
        return i, 0
    # Re-sign per chunk: each top-up is small and finishes well inside the
    # ten-minute window, which is the whole point.
    url = resolve(api, token)
    tmp = path.with_suffix(".part")
    subprocess.run(
        ["curl", "-sL", "--fail", "--retry", "6", "--retry-all-errors",
         "--range", f"{start + have}-{end}", "-o", str(tmp), url], check=True)
    with open(path, "ab") as dst, open(tmp, "rb") as src:
        dst.write(src.read())
    tmp.unlink(missing_ok=True)
    return i, path.stat().st_size - have


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("api"); ap.add_argument("tmpdir"); ap.add_argument("output")
    ap.add_argument("--start", type=int, required=True)
    ap.add_argument("--chunk", type=int, required=True)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--size", type=int, required=True)
    ap.add_argument("--method", default="deflate")
    ap.add_argument("--token", default="")
    a = ap.parse_args()

    tmp = Path(a.tmpdir)
    last = a.start + a.size - 1

    jobs = []
    for i in range(a.count):
        s = a.start + i * a.chunk
        e = min(s + a.chunk - 1, last)
        if s > e:
            continue
        jobs.append((i, tmp / f"p{i}", e - s + 1, s, e, a.api, a.token))

    missing = sum(max(0, w - (p.stat().st_size if p.exists() else 0))
                  for _, p, w, _, _, _, _ in jobs)
    print(f"missing {missing / 1048576:.0f} MB across "
          f"{sum(1 for _, p, w, *_ in jobs if (p.stat().st_size if p.exists() else 0) < w)}"
          f" chunk(s)", flush=True)

    if missing:
        with ThreadPoolExecutor(max_workers=6) as pool:
            for i, got in pool.map(top_up, jobs):
                if got:
                    print(f"  chunk {i}: +{got / 1048576:.0f} MB", flush=True)

    for i, p, w, *_ in jobs:
        have = p.stat().st_size if p.exists() else 0
        if have != w:
            sys.exit(f"chunk {i} still short: {have} of {w}")

    print("joining and inflating…", flush=True)
    with open(a.output, "wb") as out:
        if a.method == "store":
            for i, p, *_ in jobs:
                out.write(p.read_bytes())
        else:
            d = zlib.decompressobj(-zlib.MAX_WBITS)
            for i, p, *_ in jobs:
                out.write(d.decompress(p.read_bytes()))
            out.write(d.flush())

    print(f"done: {Path(a.output).stat().st_size / 1048576:.0f} MB", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
