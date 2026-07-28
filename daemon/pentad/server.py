"""JSON-lines IPC server.

One protocol, two transports:

* **TCP 127.0.0.1:8787** — what the menu uses. A Unix socket would be tidier,
  but Godot 4 has no Unix-domain socket class, and loopback keeps the menu's
  code identical on macOS and on the console.
* **/run/penta/pentad.sock** — for privileged CLI tools (`pentactl`), and only
  created when that directory exists.

Replies carry the `id` of their request. Events are pushed unsolicited with
`id: null` and can land *between* a request and its reply — clients must
demultiplex rather than assume the next line is their answer.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Awaitable, Callable, Dict, Optional, Set

log = logging.getLogger("pentad.server")

Handler = Callable[[Dict[str, Any]], Awaitable[Any]]

HOST = "127.0.0.1"
PORT = 8787
UNIX_PATH = "/run/penta/pentad.sock"


class Server:
    def __init__(self) -> None:
        self._handlers: Dict[str, Handler] = {}
        self._writers: Set[asyncio.StreamWriter] = set()

    # --- Registration ---------------------------------------------------------

    def command(self, name: str) -> Callable[[Handler], Handler]:
        """Decorator registering a command handler."""
        def wrap(fn: Handler) -> Handler:
            self._handlers[name] = fn
            return fn
        return wrap

    def register(self, name: str, fn: Handler) -> None:
        self._handlers[name] = fn

    @property
    def commands(self) -> list:
        return sorted(self._handlers)

    # --- Events ---------------------------------------------------------------

    def emit(self, event: str, **args: Any) -> None:
        """Push an event to every connected client. Never raises."""
        line = (json.dumps({"id": None, "event": event, "args": args}) + "\n").encode()
        for w in list(self._writers):
            try:
                w.write(line)
            except Exception:
                self._writers.discard(w)

    # --- Serving --------------------------------------------------------------

    async def serve(self) -> None:
        servers = [await asyncio.start_server(self._client, HOST, PORT)]
        log.info("listening on %s:%d", HOST, PORT)

        unix = await self._maybe_unix()
        if unix:
            servers.append(unix)

        await asyncio.gather(*(s.serve_forever() for s in servers))

    async def _maybe_unix(self) -> Optional[asyncio.AbstractServer]:
        import os
        import stat

        directory = os.path.dirname(UNIX_PATH)
        if not os.path.isdir(directory):
            log.debug("%s absent; skipping unix socket", directory)
            return None
        try:
            if os.path.exists(UNIX_PATH):
                os.unlink(UNIX_PATH)
            srv = await asyncio.start_unix_server(self._client, UNIX_PATH)
            os.chmod(UNIX_PATH, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IWGRP)
            log.info("listening on %s", UNIX_PATH)
            return srv
        except OSError as exc:
            log.warning("unix socket unavailable: %s", exc)
            return None

    async def _client(self, reader: asyncio.StreamReader,
                      writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername") or "unix"
        log.info("client connected: %s", peer)
        self._writers.add(writer)
        try:
            while True:
                raw = await reader.readline()
                if not raw:
                    break
                await self._dispatch(raw, writer)
                await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            self._writers.discard(writer)
            try:
                writer.close()
            except Exception:
                pass
            log.info("client disconnected: %s", peer)

    async def _dispatch(self, raw: bytes, writer: asyncio.StreamWriter) -> None:
        msg_id = None
        try:
            msg = json.loads(raw)
            msg_id = msg.get("id")
            cmd = msg.get("cmd", "")
            handler = self._handlers.get(cmd)
            if handler is None:
                raise KeyError(f"unknown command {cmd!r}")
            result = await handler(msg.get("args") or {})
            reply = {"id": msg_id, "ok": True, "result": result if result is not None else {}}
        except Exception as exc:                                   # noqa: BLE001
            # A bad command must never take the daemon down — the menu is the
            # only UI the console has, and it needs an answer to every request.
            log.warning("command failed: %s", exc)
            reply = {"id": msg_id, "ok": False, "error": str(exc)}
        writer.write((json.dumps(reply) + "\n").encode())
