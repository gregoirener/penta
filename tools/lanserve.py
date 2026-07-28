#!/usr/bin/env python3
"""Range-capable static file server for handing the image to the target machine.

`python3 -m http.server` ignores Range requests, so `curl -C -` cannot resume
against it — a dropped transfer means starting the whole 500 MB again. On a
flaky link that is the difference between "re-run it" and "give up".

    ./tools/lanserve.py /tmp/penta-serve

Serves one directory read-only on all interfaces. Ctrl-C to stop.
"""

from __future__ import annotations

import http.server
import os
import socketserver
import sys
from pathlib import Path

PORT = int(os.environ.get("PORT", "8000"))


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler plus the one feature it is missing."""

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        if not os.path.isfile(path):
            self.send_error(404, "File not found")
            return None

        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        if not rng:
            return super().send_head()

        # Only the single-range form matters here: `bytes=START-` from curl -C -.
        try:
            units, _, spec = rng.partition("=")
            if units.strip().lower() != "bytes":
                raise ValueError(units)
            start_s, _, end_s = spec.partition("-")
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else size - 1
            if start >= size or start < 0 or end < start:
                raise ValueError(rng)
        except ValueError:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None

        end = min(end, size - 1)
        length = end - start + 1

        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

        # copyfile() would send to EOF and ignore the range, so cap it here.
        self._remaining = length
        return _Capped(f, length)

    def end_headers(self):
        # Advertise range support so clients bother trying to resume.
        if "Accept-Ranges" not in self._headers_buffer_names():
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def _headers_buffer_names(self):
        return b"".join(getattr(self, "_headers_buffer", [])).decode(
            "latin-1", "replace")

    def log_message(self, fmt, *args):
        sys.stdout.write("%s - %s\n" % (self.client_address[0], fmt % args))
        sys.stdout.flush()


class _Capped:
    """File wrapper that yields at most `limit` bytes, for ranged responses."""

    def __init__(self, fh, limit: int) -> None:
        self._fh = fh
        self._left = limit

    def read(self, n: int = -1) -> bytes:
        if self._left <= 0:
            return b""
        if n < 0 or n > self._left:
            n = self._left
        data = self._fh.read(n)
        self._left -= len(data)
        return data

    def close(self) -> None:
        self._fh.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 1
    os.chdir(root)

    with Server(("0.0.0.0", PORT), RangeHandler) as srv:
        print(f"serving {root} on port {PORT} (resumable)")
        for f in sorted(root.iterdir()):
            if f.is_file():
                print(f"  {f.name}  {f.stat().st_size / 1048576:.0f} MB")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
