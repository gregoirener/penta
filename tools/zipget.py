#!/usr/bin/env python3
"""Fetch a single file out of a remote zip, in parallel, without the rest.

A GitHub artifact bundles every file it was given into one zip. Downloading it
to reach one member means paying for all of them — for us, 4 GB transferred to
use 1.8 GB, over a link GitHub throttles to a crawl.

A zip's central directory sits at the end and records where each member starts,
so two small range requests are enough to locate the member we want. Then only
that span is fetched, split across connections because the throttle is
per-connection.

    ./tools/zipget.py <url> <member-glob> <output> [--conns N] [--token TOK]
"""

from __future__ import annotations

import argparse
import fnmatch
import struct
import subprocess
import sys
import tempfile
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

EOCD_SIG = b"PK\x05\x06"
EOCD64_LOC_SIG = b"PK\x06\x07"
EOCD64_SIG = b"PK\x06\x06"
CEN_SIG = b"PK\x01\x02"


def curl(url: str, token: str, start: int | None = None,
         end: int | None = None, out: str | None = None) -> bytes:
    cmd = ["curl", "-sL", "--fail", "--retry", "8", "--retry-all-errors",
           "--retry-delay", "2"]
    if token:
        cmd += ["-H", f"Authorization: token {token}"]
    if start is not None:
        cmd += ["--range", f"{start}-{end if end is not None else ''}"]
    if out:
        cmd += ["-o", out, url]
        subprocess.run(cmd, check=True)
        return b""
    cmd.append(url)
    return subprocess.run(cmd, check=True, capture_output=True).stdout


def resolve(url: str, token: str) -> tuple[str, int]:
    """Follow redirects by hand; signed CDN URLs must be reused verbatim."""
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
        final, tok = loc, ""          # the signed URL carries its own auth
    head = subprocess.run(["curl", "-sI", final], capture_output=True, text=True).stdout
    size = 0
    for line in head.splitlines():
        if line.lower().startswith("content-length:"):
            size = int(line.split(":", 1)[1].strip())
    return final, size


def find_member(url: str, size: int, pattern: str) -> tuple[int, int, int, str]:
    """(local_header_offset, compressed_size, method, name) for the match."""
    # Central directory lives at the end; 128 KB covers the EOCD and a small
    # directory comfortably.
    tail_len = min(size, 131072)
    tail = curl(url, "", size - tail_len, size - 1)

    idx = tail.rfind(EOCD_SIG)
    if idx < 0:
        sys.exit("no zip end-of-central-directory found")

    cen_size, cen_off = struct.unpack_from("<II", tail, idx + 12)

    # Zip64: a 4 GB artifact is exactly where the 32-bit fields give out.
    if cen_off == 0xFFFFFFFF or cen_size == 0xFFFFFFFF:
        loc = tail.rfind(EOCD64_LOC_SIG)
        if loc < 0:
            sys.exit("zip64 locator missing")
        eocd64_off = struct.unpack_from("<Q", tail, loc + 8)[0]
        head = curl(url, "", eocd64_off, eocd64_off + 55)
        if head[:4] != EOCD64_SIG:
            sys.exit("zip64 end-of-central-directory missing")
        cen_size, cen_off = struct.unpack_from("<QQ", head, 40)

    cen = curl(url, "", cen_off, cen_off + cen_size - 1)

    pos = 0
    while pos < len(cen) - 4:
        if cen[pos:pos + 4] != CEN_SIG:
            break
        method, = struct.unpack_from("<H", cen, pos + 10)
        csize, usize = struct.unpack_from("<II", cen, pos + 20)
        n, m, k = struct.unpack_from("<HHH", cen, pos + 28)
        lho, = struct.unpack_from("<I", cen, pos + 42)
        name = cen[pos + 46:pos + 46 + n].decode("utf-8", "replace")

        extra = cen[pos + 46 + n:pos + 46 + n + m]
        if 0xFFFFFFFF in (csize, usize, lho):        # zip64 extra field
            e = 0
            while e < len(extra) - 4:
                tag, ln = struct.unpack_from("<HH", extra, e)
                if tag == 0x0001:
                    vals = struct.unpack_from("<" + "Q" * (ln // 8), extra, e + 4)
                    it = iter(vals)
                    if usize == 0xFFFFFFFF:
                        usize = next(it)
                    if csize == 0xFFFFFFFF:
                        csize = next(it)
                    if lho == 0xFFFFFFFF:
                        lho = next(it)
                    break
                e += 4 + ln

        if fnmatch.fnmatch(name, pattern):
            return lho, csize, method, name
        pos += 46 + n + m + k

    sys.exit(f"no member matching {pattern!r} in the archive")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("pattern")
    ap.add_argument("output")
    ap.add_argument("--conns", type=int, default=8)
    ap.add_argument("--token", default="")
    a = ap.parse_args()

    print("resolving…", flush=True)
    url, size = resolve(a.url, a.token)
    if not size:
        sys.exit("server did not report a size")
    print(f"archive: {size / 1048576:.0f} MB", flush=True)

    lho, csize, method, name = find_member(url, size, a.pattern)
    print(f"member : {name}  ({csize / 1048576:.0f} MB, "
          f"{'stored' if method == 0 else 'deflated'})", flush=True)
    print(f"saving : {(size - csize) / 1048576:.0f} MB not downloaded", flush=True)

    # The local header repeats the name and extra field, and its lengths are
    # the authoritative ones for where the data actually begins.
    lh = curl(url, "", lho, lho + 29)
    n, m = struct.unpack_from("<HH", lh, 26)
    data_start = lho + 30 + n + m
    data_end = data_start + csize - 1

    tmp = Path(tempfile.mkdtemp())
    chunk = (csize + a.conns - 1) // a.conns
    jobs = []
    for i in range(a.conns):
        s = data_start + i * chunk
        e = min(s + chunk - 1, data_end)
        if s > e:
            continue
        jobs.append((i, s, e))

    print(f"downloading over {len(jobs)} connections…", flush=True)
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        list(pool.map(lambda j: curl(url, "", j[1], j[2], str(tmp / f"p{j[0]}")), jobs))

    with open(a.output, "wb") as out:
        if method == 0:
            for i, _, _ in jobs:
                out.write((tmp / f"p{i}").read_bytes())
        else:
            d = zlib.decompressobj(-zlib.MAX_WBITS)
            for i, _, _ in jobs:
                out.write(d.decompress((tmp / f"p{i}").read_bytes()))
            out.write(d.flush())

    for i, _, _ in jobs:
        (tmp / f"p{i}").unlink(missing_ok=True)
    tmp.rmdir()

    print(f"done: {Path(a.output).stat().st_size / 1048576:.0f} MB", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
