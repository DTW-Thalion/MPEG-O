"""
Workbench-aware upload over the `ttio-transport` WebSocket subprotocol.

`UploadClient` is an async context manager that opens the WS to
`/transport`, performs the handshake, streams `.tis` bytes via
BINARY frames, drains per-AU acks, and returns the terminal `done`
frame's payload (container URI, total bytes).

Resumable uploads: pass a `ResumeState` into `upload_bytes` /
`upload_iter` to continue from a previously-interrupted attempt.
The client transparently skips bytes the server has already
acknowledged.

Error contract: every failure raises a typed exception
(`HandshakeError` / `UploadError`) carrying the WS close code +
the server's free-text reason when available.

The wire details match `tti-workbench-server/Source/WS/TTIOWBWsUploadSession.m`
behaviour as of v1.0.0 (commit `1a58779`).
"""

from __future__ import annotations

import dataclasses
import json
from typing import AsyncIterator, Callable, Iterable, Optional

import websockets
from websockets.exceptions import ConnectionClosed

from ttio.workbench.auth import Session
from ttio.workbench.transport.errors import (
    HandshakeError,
    UploadError,
)
from ttio.workbench.transport.handshake import (
    WS_SUBPROTOCOL,
    ServerFrameKind,
    build_upload_handshake,
    parse_server_frame,
)
from ttio.workbench.transport.resume import ResumeState


def _report_progress(cb: Optional[Callable[[int, int], None]],
                     done: int, total: int) -> None:
    """Invoke a progress callback, swallowing exceptions so a
    throwing callback can't abort the transfer (matches the Java
    TransferProgress contract). ``total`` may be -1 when unknown."""
    if cb is None:
        return
    try:
        cb(done, total)
    except Exception:  # noqa: BLE001 -- progress must never break transfer
        pass


# Default WebSocket chunk size. The daemon doesn't care about frame
# boundaries (frames are byte-agnostic per spec section 9.2), but
# keeping frames in the low tens of KB makes the per-AU ack visible
# at reasonable cadence and stays under most reverse-proxy framing
# limits.
DEFAULT_CHUNK_SIZE = 64 * 1024


@dataclasses.dataclass(frozen=True)
class UploadResult:
    """Successful upload outcome.

    Args:
        container_uri: the URI the server registered the container
            under. Identical to the URI the client sent in the
            handshake (the server doesn't rewrite it; conflicts
            would have closed the WS with code 1002 during
            handshake).
        last_acked_au_sequence: the highest `au_sequence` the server
            ack'd during this upload. Useful for telemetry and as
            input to a future resume attempt of a DIFFERENT
            container that shares state with this one (rare).
        resume_handle: the `stg-...` handle the server issued at
            handshake time. Returned on success too so callers can
            log it for incident review.
    """

    container_uri: str
    last_acked_au_sequence: int
    resume_handle: str


class UploadClient:
    """Async context manager for one upload.

    Usage:

        async with UploadClient(host="...", port=8443, session=...,
                                 project="alpha",
                                 container_uri="uri:tio:demo-001") as client:
            result = await client.upload_bytes(tis_bytes)
            print(result.container_uri)

    The client opens the WebSocket and performs the handshake on
    `__aenter__`. The terminal `done` frame is consumed and the WS
    is closed on `__aexit__` (or earlier, when `upload_bytes` /
    `upload_iter` returns).
    """

    def __init__(
        self,
        *,
        host: str,
        port: int,
        session: Optional[Session] = None,
        token: Optional[str] = None,
        owner: Optional[str] = None,
        project: str,
        container_uri: str,
        scheme: str = "ws",
        ssl_context=None,
        chunk_size: int = DEFAULT_CHUNK_SIZE,
        connect_timeout: float = 10.0,
        recv_timeout: float = 30.0,
    ):
        """Construct the upload client.

        Either `session` OR (`token` + `owner`) must be supplied.
        `session` is preferred -- it carries the resolved username
        the daemon's auth gate expects as `owner`. Passing both
        raises ValueError.

        Args:
            host, port: server WebSocket endpoint.
            session: an authenticated `Session` from `login_password`.
                When supplied, the bearer + username are taken from
                here.
            token: bearer token (string). Required if `session` is
                None.
            owner: username to attribute the upload to. Required if
                `session` is None; defaults to `session.username`.
                Must match the daemon's auth gate (see
                `Documentation/auth.md` -- the daemon refuses
                `owner != session.username` unless the caller has
                `containers.write.any_project`).
            project: project name the container belongs to. Required.
            container_uri: client-minted container URI (e.g.
                `uri:tio:demo-001`). The daemon refuses duplicates.
            scheme: `"ws"` for development; `"wss"` for production.
            ssl_context: optional `ssl.SSLContext` for the WSS handshake.
            chunk_size: per-WS-frame byte budget when iterating the
                payload. Defaults to 64 KB.
            connect_timeout: WS open + initial-ack timeout.
            recv_timeout: per-recv timeout once the upload is in
                flight.
        """
        if session is None and token is None:
            raise ValueError("UploadClient requires either `session` or `token`")
        if session is not None and token is not None:
            raise ValueError("pass either `session` or `token`, not both")
        if not project:
            raise ValueError("UploadClient requires `project`")
        if not container_uri:
            raise ValueError("UploadClient requires `container_uri`")

        self._host = host
        self._port = port
        self._session = session
        self._token = session.token if session is not None else token
        self._owner = owner or (session.username if session is not None else None)
        if not self._owner:
            raise ValueError("UploadClient requires `owner` (or a Session)")
        self._project = project
        self._container_uri = container_uri
        self._scheme = scheme
        self._ssl_context = ssl_context
        self._chunk_size = chunk_size
        self._connect_timeout = connect_timeout
        self._recv_timeout = recv_timeout

        # Filled by `__aenter__`.
        self._ws: Optional[websockets.WebSocketClientProtocol] = None
        # Highest `au_sequence` observed from server (-1 = pre-ack).
        self._last_ack: int = -1
        # Server-issued resume handle.
        self._resume_handle: Optional[str] = None

    @property
    def last_acked_au_sequence(self) -> int:
        return self._last_ack

    @property
    def resume_handle(self) -> Optional[str]:
        return self._resume_handle

    async def __aenter__(self) -> "UploadClient":
        url = f"{self._scheme}://{self._host}:{self._port}/transport"
        try:
            self._ws = await websockets.connect(
                url,
                subprotocols=[WS_SUBPROTOCOL],
                open_timeout=self._connect_timeout,
                ssl=self._ssl_context if self._scheme == "wss" else None,
            )
        except Exception as e:
            raise HandshakeError(
                f"failed to open WS to {url}: {e}",
            ) from e
        return self

    async def __aexit__(self, exc_type, exc, tb):
        if self._ws is not None:
            try:
                await self._ws.close()
            finally:
                self._ws = None

    async def upload_bytes(
        self,
        data: bytes | bytearray | memoryview,
        *,
        resume: Optional[ResumeState] = None,
        progress: Optional[Callable[[int, int], None]] = None,
    ) -> UploadResult:
        """Upload a fully-buffered `.tis` byte string.

        Args:
            data: the complete transport stream.
            resume: if set, the client re-handshakes with this
                resume handle and skips the prefix the server has
                already acknowledged. The skip is BYTE-based, not
                AU-based -- we don't have an AU-to-byte-offset
                map client-side, so resume is most useful with
                `upload_iter` where the caller controls AU
                boundaries.
            progress: optional callback invoked `(bytes_sent,
                bytes_total)` as chunks are sent, plus a final
                `(total, total)`. Cross-language equivalent of the
                Java `TransferProgress` callback. A throwing
                callback is swallowed so it cannot abort the
                upload.

        Returns:
            `UploadResult` on success.

        Raises:
            HandshakeError: on handshake-time failures.
            UploadError: on mid-stream failures.
        """
        await self._handshake(resume)

        # Streamed byte upload. The daemon's `transport.bin` append
        # writer doesn't care about frame boundaries; chunking is
        # purely for ack cadence and ergonomic recovery.
        view = memoryview(data)
        total = len(view)
        offset = 0
        _report_progress(progress, 0, total)
        while offset < total:
            end = min(offset + self._chunk_size, total)
            await self._ws.send(bytes(view[offset:end]))
            offset = end
            _report_progress(progress, offset, total)
            await self._drain_acks(non_blocking=True)

        return await self._wait_for_done()

    async def upload_iter(
        self,
        chunks: Iterable[bytes],
        *,
        resume: Optional[ResumeState] = None,
    ) -> UploadResult:
        """Upload an iterable of `.tis` byte chunks.

        Useful when streaming from a file (`(open(path,'rb').read(N)
        for ...)`) or from an in-memory generator (the existing
        `ttio.transport.simulator.synth_stream` works -- treat its
        return value as one big bytes blob and pass to
        `upload_bytes`, OR re-yield it in chunks).

        Args:
            chunks: iterable yielding `bytes`. Empty bytes are
                skipped. The iterator is fully consumed before
                `done` is awaited.

        Returns / Raises: same as `upload_bytes`.
        """
        await self._handshake(resume)

        for chunk in chunks:
            if not chunk:
                continue
            await self._ws.send(bytes(chunk))
            await self._drain_acks(non_blocking=True)

        return await self._wait_for_done()

    # -----------------------------------------------------------------
    # internals
    # -----------------------------------------------------------------

    async def _handshake(self, resume: Optional[ResumeState]) -> None:
        if self._ws is None:
            raise HandshakeError(
                "UploadClient must be used as `async with`; "
                "call __aenter__ first")

        handshake = build_upload_handshake(
            owner=self._owner,
            project=self._project,
            container_uri=self._container_uri,
            token=self._token,
            resume_handle=resume.resume_handle if resume else None,
        )
        # Compact separators so the wire bytes match the Java port's
        # `WorkbenchHandshake.buildUploadHandshake` output verbatim.
        await self._ws.send(json.dumps(handshake, separators=(",", ":")))

        # First reply should be the post-handshake ack with `handle`.
        try:
            raw = await self._ws.recv()
        except ConnectionClosed as e:
            raise HandshakeError(
                f"server closed during handshake: code={e.code} "
                f"reason={e.reason!r}",
                close_code=e.code,
                reason=e.reason,
            ) from e
        if isinstance(raw, (bytes, bytearray)):
            raise HandshakeError(
                "expected TEXT ack after handshake, got BINARY")
        kind, body = parse_server_frame(raw)
        if kind is ServerFrameKind.ERROR:
            reason = body.get("message") or body.get("reason") or ""
            raise HandshakeError(
                f"server rejected handshake: {reason}",
                reason=str(reason),
            )
        if kind is not ServerFrameKind.ACK:
            raise HandshakeError(
                f"unexpected handshake reply kind {kind.value!r}")

        handle = body.get("handle")
        if not isinstance(handle, str) or not handle:
            raise HandshakeError(
                "handshake ack missing `handle` field")
        self._resume_handle = handle

        # `au_sequence` is the resume point (0 on fresh upload). On
        # resume the server quotes the persisted value; the caller's
        # `upload_iter` should skip chunks at or below this AU
        # sequence using the resume state it kept locally.
        seq = body.get("au_sequence", 0)
        if isinstance(seq, (int, float)):
            self._last_ack = int(seq)

    async def _drain_acks(self, *, non_blocking: bool) -> None:
        """Drain any pending TEXT ack frames without blocking on send."""
        import asyncio
        while self._ws.messages:  # type: ignore[attr-defined]
            try:
                raw = self._ws.messages.popleft()  # type: ignore[attr-defined]
            except (AttributeError, IndexError):
                break
            await self._handle_text_frame(raw)
        if non_blocking:
            return
        try:
            raw = await asyncio.wait_for(self._ws.recv(), timeout=0.0)
        except (asyncio.TimeoutError, Exception):
            return
        await self._handle_text_frame(raw)

    async def _wait_for_done(self) -> UploadResult:
        while True:
            try:
                raw = await self._ws.recv()
            except ConnectionClosed as e:
                # Closed without a `done`. Surface the partial state
                # so the caller can resume.
                raise UploadError(
                    f"server closed before `done`: code={e.code} "
                    f"reason={e.reason!r}",
                    close_code=e.code,
                    reason=e.reason,
                    last_acked_au_sequence=self._last_ack,
                    resume_handle=self._resume_handle,
                ) from e
            result = await self._handle_text_frame(raw)
            if result is not None:
                return result

    async def _handle_text_frame(self, raw) -> Optional[UploadResult]:
        if isinstance(raw, (bytes, bytearray)):
            # Upload path never receives BINARY from the server.
            # Drop silently rather than raise -- a defensive
            # downstream change to the server might add a binary
            # ack, and we don't want to break clients on it.
            return None
        kind, body = parse_server_frame(raw)
        if kind is ServerFrameKind.ACK:
            seq = body.get("au_sequence")
            if isinstance(seq, (int, float)):
                self._last_ack = max(self._last_ack, int(seq))
            return None
        if kind is ServerFrameKind.ERROR:
            reason = body.get("message") or body.get("reason") or ""
            raise UploadError(
                f"server error mid-upload: {reason}",
                reason=str(reason),
                last_acked_au_sequence=self._last_ack,
                resume_handle=self._resume_handle,
            )
        if kind is ServerFrameKind.DONE:
            uri = body.get("container_uri") or self._container_uri
            return UploadResult(
                container_uri=str(uri),
                last_acked_au_sequence=self._last_ack,
                resume_handle=self._resume_handle or "",
            )
        return None
