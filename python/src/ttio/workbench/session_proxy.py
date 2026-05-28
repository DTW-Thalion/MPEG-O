"""
ttio.workbench.session_proxy -- WS attach helper for interactive sessions.

Opens `wss://host:port/v1/sessions/{id}/` with the
`ttio-session-proxy` subprotocol, sends the JSON attach frame,
then pumps raw bytes bidirectionally between the engine subprocess
(server-side) and a user-supplied byte stream pair (typically
stdin/stdout, but could be in-memory queues for testing).

Wire shape (per the v1.0 wire-contract survey + `Documentation/
session-protocol.md`):

  Subprotocol: `ttio-session-proxy`
  URL:         `wss://<host>:<port>/v1/sessions/{id}/`

  First frame (TEXT, JSON):
    {
      "action": "attach",     # required, must be literally "attach"
      "token":  "ttiowbs_...", # required
      "path":   "/api/kernels" # optional, defaults to "/"
    }

  Subsequent frames: raw BINARY bytes from the engine subprocess
  (stdout/stderr) in one direction; raw BINARY bytes from the
  caller (stdin) in the other. No framing on top.

Close codes:
  1000 -- clean close (either side initiated)
  1008 -- auth / policy (5 decisions: missing token, session not
          found, forbidden, not running, malformed handshake)
  1011 -- server error (session not running at attach, backend
          subprocess connect failed)

The server applies ring-buffer backpressure (4 MB rings with
75/25 hysteresis) to either direction. The client doesn't need
to implement matching logic; the WS library's flow-control
hooks pause RX automatically when the OS socket buffer fills.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
from typing import Optional

import websockets
from websockets.exceptions import ConnectionClosed

from ttio.workbench.transport.handshake import OutputModeLiteral  # noqa: F401


SESSION_PROXY_SUBPROTOCOL = "ttio-session-proxy"


def build_attach_handshake(
    *,
    token: str,
    path: str = "/",
) -> dict:
    """Build the JSON attach-frame body.

    Args:
        token: workbench bearer (`ttiowbs_...`).
        path: optional sub-path the proxy forwards to inside the
            engine. Defaults to `/`. The server applies a defensive
            leading-slash prepend if absent (see
            `Source/Sessions/TTIOWBSessionProxy.m:54-62`).

    Returns:
        dict ready for `json.dumps(..., separators=(",", ":"))`.
    """
    if not token:
        raise ValueError("attach handshake requires `token`")
    if not path:
        path = "/"
    if not path.startswith("/"):
        path = "/" + path
    return {"action": "attach", "token": token, "path": path}


def session_proxy_url(
    *,
    host: str,
    port: int,
    session_id: str,
    scheme: str = "ws",
) -> str:
    """Build the WS proxy URL. Mirrors the server's mount path on
    `/v1/sessions/{id}/`.

    The server's mount config requires the trailing slash; we
    always emit it.
    """
    return f"{scheme}://{host}:{port}/v1/sessions/{session_id}/"


@dataclasses.dataclass(frozen=True)
class SessionProxyResult:
    """Outcome of an attach session.

    Args:
        close_code: WS close code (1000 / 1008 / 1011).
        close_reason: server-supplied reason text (may be empty).
        bytes_to_backend: total bytes pumped from client to engine.
        bytes_from_backend: total bytes received from engine.
    """
    close_code: int
    close_reason: str
    bytes_to_backend: int
    bytes_from_backend: int


class SessionProxyAttach:
    """Async helper that attaches to a session and proxies bytes.

    Usage:

        async with SessionProxyAttach(host, port, session_id, token) as proxy:
            await proxy.run(
                stdin_reader=sys.stdin.buffer,
                stdout_writer=sys.stdout.buffer,
            )

    For non-stdin-based use (e.g. a Jupyter HTTP-over-WS bridge),
    pass any object with `read(n)` / `write(b)` shape; the helper
    pumps in 16 KB chunks.
    """

    DEFAULT_CHUNK_SIZE = 16 * 1024

    def __init__(
        self,
        *,
        host: str,
        port: int,
        session_id: str,
        token: str,
        path: str = "/",
        scheme: str = "ws",
        ssl_context=None,
        connect_timeout: float = 10.0,
    ):
        """Bind the helper to a session-proxy endpoint.

        Parameters
        ----------
        host : str
            Workbench server hostname.
        port : int
            WS listener port.
        session_id : str
            Target session identifier; the session must be in the
            ``running`` state at attach time.
        token : str
            Workbench bearer (``ttiowbs_...``).
        path : str, optional
            Sub-path the proxy forwards to inside the engine.
            Default ``"/"``.
        scheme : str, optional
            ``"ws"`` or ``"wss"``. Default ``"ws"``.
        ssl_context : ssl.SSLContext, optional
            Required when ``scheme == "wss"``. Pass a configured
            context for cert pinning; None falls back to default
            verification.
        connect_timeout : float, optional
            Max wall-clock seconds to wait for the WS open
            handshake. Default 10.
        """
        self._host = host
        self._port = port
        self._session_id = session_id
        self._token = token
        self._path = path
        self._scheme = scheme
        self._ssl_context = ssl_context
        self._connect_timeout = connect_timeout
        self._ws: Optional[websockets.WebSocketClientProtocol] = None

    async def __aenter__(self) -> "SessionProxyAttach":
        """Open the WS connection and send the attach handshake.

        Returns
        -------
        SessionProxyAttach
            Self, ready for :meth:`run`.

        Raises
        ------
        RuntimeError
            If the WS open fails for any reason (network, TLS,
            timeout). The underlying exception is chained.
        """
        url = session_proxy_url(
            host=self._host, port=self._port,
            session_id=self._session_id, scheme=self._scheme)
        try:
            self._ws = await websockets.connect(
                url,
                subprotocols=[SESSION_PROXY_SUBPROTOCOL],
                open_timeout=self._connect_timeout,
                ssl=self._ssl_context if self._scheme == "wss" else None,
            )
        except Exception as e:
            raise RuntimeError(
                f"session-proxy WS open failed: {e}") from e
        # Send the attach handshake as the first frame.
        handshake = build_attach_handshake(token=self._token, path=self._path)
        await self._ws.send(json.dumps(handshake, separators=(",", ":")))
        return self

    async def __aexit__(self, exc_type, exc, tb):
        """Close the WS connection on context exit.

        Parameters
        ----------
        exc_type, exc, tb
            Standard async context-manager exit triple. Exceptions
            from the user block propagate after the WS is closed.
        """
        if self._ws is not None:
            try:
                await self._ws.close()
            finally:
                self._ws = None

    async def run(
        self,
        *,
        stdin_reader,
        stdout_writer,
        chunk_size: int = DEFAULT_CHUNK_SIZE,
    ) -> SessionProxyResult:
        """Pump bytes between `stdin_reader` -> WS and WS -> `stdout_writer`
        until the WS closes.

        Args:
            stdin_reader: file-like with `.read(n)`-returning bytes
                or an asyncio Queue with `await get()` -> bytes.
            stdout_writer: file-like with `.write(b)` + `.flush()`.
            chunk_size: per-WS-frame budget for outbound bytes.

        Returns:
            `SessionProxyResult` with close info + byte counts.
        """
        if self._ws is None:
            raise RuntimeError(
                "SessionProxyAttach must be used as async with")

        to_backend = 0
        from_backend = 0

        async def pump_stdin():
            nonlocal to_backend
            loop = asyncio.get_running_loop()
            while True:
                chunk = await loop.run_in_executor(
                    None, _read_chunk, stdin_reader, chunk_size)
                if not chunk:
                    break
                try:
                    await self._ws.send(chunk)
                    to_backend += len(chunk)
                except ConnectionClosed:
                    break

        async def pump_backend():
            nonlocal from_backend
            while True:
                try:
                    msg = await self._ws.recv()
                except ConnectionClosed:
                    break
                if isinstance(msg, (bytes, bytearray)):
                    stdout_writer.write(msg)
                    if hasattr(stdout_writer, "flush"):
                        stdout_writer.flush()
                    from_backend += len(msg)
                # TEXT frames after attach should not occur; drop.

        stdin_task = asyncio.create_task(pump_stdin())
        backend_task = asyncio.create_task(pump_backend())

        # When EITHER side closes, cancel the other. The WS itself
        # mirrors close events through `requestCloseWithCode:` on
        # the server, so the surviving wsi will drop shortly anyway.
        done, pending = await asyncio.wait(
            {stdin_task, backend_task},
            return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass

        close_code = self._ws.close_code or 1000
        close_reason = self._ws.close_reason or ""
        return SessionProxyResult(
            close_code=close_code,
            close_reason=close_reason,
            bytes_to_backend=to_backend,
            bytes_from_backend=from_backend,
        )


def _read_chunk(reader, n: int) -> bytes:
    """Adapter for stream-like `reader.read(n)`. Used inside a
    thread-pool executor so blocking stdin reads don't stall the
    event loop. Returns empty bytes on EOF."""
    chunk = reader.read(n)
    if chunk is None:
        return b""
    return bytes(chunk)


# Legacy stub name kept for back-compat with W2 imports.
SessionProxy = SessionProxyAttach
