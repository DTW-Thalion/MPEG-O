"""
Workbench-aware download over the `ttio-transport` WebSocket subprotocol.

`DownloadClient` is an async context manager that opens the WS to
`/transport`, performs the download handshake (with optional
selective-access filters), drains the BINARY `.tis` payload + any
TEXT stats / progress frames, and returns the full payload plus
metadata when the server emits its terminal `done` frame.

Three output modes mirror the daemon's
`Source/WS/TTIOWBWsDownloadHandshake.m`:

  - `"binary"` -- pure `.tis` stream, no stats frames mixed in. The
    typical fetch-and-save path.
  - `"stats-only"` -- per-AU stats JSON only, no binary. Useful for
    UC-05 "container inspection" without downloading the payload.
  - `"stats-with-payload"` -- both interleaved; the AU stats frames
    arrive immediately before each AU's binary chunk.

Cross-project access is policed by the daemon's auth gate and
returns WS close code 1011 with `{"type":"error","reason":"container
not found"}` (see `Documentation/auth.md`'s "Cross-project = 404,
not 403" rule). `DownloadError` carries the close code + reason
for inspection.
"""

from __future__ import annotations

import dataclasses
import json
from typing import Any, Callable, Mapping, Optional

import websockets
from websockets.exceptions import ConnectionClosed

from ttio.workbench.auth import Session
from ttio.workbench.transport.errors import (
    DownloadError,
    HandshakeError,
)
from ttio.workbench.transport.handshake import (
    WS_SUBPROTOCOL,
    OutputModeLiteral,
    ServerFrameKind,
    build_download_handshake,
    parse_server_frame,
)


FilterDict = Mapping[str, Any]
OutputMode = str  # one of OutputModeLiteral; kept as plain `str` for ergonomics


@dataclasses.dataclass(frozen=True)
class DownloadResult:
    """Outcome of one download.

    Args:
        container_uri: the URI the server emitted in its `done`
            frame (will match what the client requested).
        payload: the concatenated `.tis` byte stream. Empty when
            `output_mode="stats-only"`.
        stats_frames: list of per-AU stats objects emitted as TEXT
            frames. Non-empty only when `output_mode` includes
            stats. Each entry is the parsed JSON object verbatim
            (the daemon's stats schema is "anything with
            `au_sequence` or `dataset_id`" per
            `Tests/load/download_one.py`'s reference parser).
        binary_frame_count: number of BINARY frames the server
            emitted. Helpful for diagnostics.
        terminal_frame: the parsed `done` frame body.
    """

    container_uri: str
    payload: bytes
    stats_frames: list[dict]
    binary_frame_count: int
    terminal_frame: dict


class DownloadClient:
    """Async context manager for one download.

    Usage:

        async with DownloadClient(host="...", port=8443,
                                   session=session) as client:
            result = await client.download(
                container_uri="uri:tio:demo-001",
                filter={"ms_level": 1, "retention_time_min": 12.0},
            )
            with open("subset.tio", "wb") as f:
                f.write(result.payload)
    """

    def __init__(
        self,
        *,
        host: str,
        port: int,
        session: Optional[Session] = None,
        token: Optional[str] = None,
        owner: Optional[str] = None,
        scheme: str = "ws",
        ssl_context=None,
        connect_timeout: float = 10.0,
        recv_timeout: float = 30.0,
    ):
        """Construct the download client. Auth wiring mirrors `UploadClient`.

        Args:
            host, port: server WebSocket endpoint.
            session: an authenticated `Session`. Either this or
                `token` is required.
            token: bearer token; mutually exclusive with `session`.
            owner: username for the handshake `owner` field. The
                v1.0 server uses this to gate cross-owner access
                under the `containers.read.any_project` capability.
                Defaults to `session.username` when `session` is
                set; otherwise required.
            scheme: `"ws"` or `"wss"`.
            ssl_context: optional `ssl.SSLContext`.
            connect_timeout: WS open + initial-ack timeout.
            recv_timeout: per-recv timeout once the download is in
                flight.
        """
        if session is None and token is None:
            raise ValueError("DownloadClient requires either `session` or `token`")
        if session is not None and token is not None:
            raise ValueError("pass either `session` or `token`, not both")
        self._host = host
        self._port = port
        self._session = session
        self._token = session.token if session is not None else token
        self._owner = owner or (session.username if session is not None else None)
        self._scheme = scheme
        self._ssl_context = ssl_context
        self._connect_timeout = connect_timeout
        self._recv_timeout = recv_timeout

        self._ws: Optional[websockets.WebSocketClientProtocol] = None

    async def __aenter__(self) -> "DownloadClient":
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

    async def download(
        self,
        *,
        container_uri: str,
        filter: Optional[FilterDict] = None,
        output_mode: OutputMode = OutputModeLiteral.BINARY.value,
        max_au: int = 0,
        progress: Optional[Callable[[int, int], None]] = None,
    ) -> DownloadResult:
        """Drive one download to completion.

        Args:
            container_uri: target container.
            filter: optional selective-access predicates. Validated
                client-side against the daemon's accepted filter
                key set; unknown keys raise `ValueError` rather
                than letting the server reject the handshake.
            output_mode: one of the `OutputModeLiteral` strings.
            max_au: cap the emitted AU count to this number; 0 =
                no cap.

        Returns:
            `DownloadResult` on success.

        Raises:
            HandshakeError: handshake failed (network, auth, bad
                container URI).
            DownloadError: server emitted an error frame or closed
                without `done`. The close code + reason are
                captured on the exception.
        """
        if self._ws is None:
            raise HandshakeError(
                "DownloadClient must be used as `async with`")

        handshake = build_download_handshake(
            container_uri=container_uri,
            token=self._token,
            owner=self._owner,
            output_mode=output_mode,
            filter=filter,
            max_au=max_au,
        )
        # Compact separators so the wire bytes match the Java port's
        # `WorkbenchHandshake.buildDownloadHandshake` output verbatim.
        await self._ws.send(json.dumps(handshake, separators=(",", ":")))

        chunks: list[bytes] = []
        stats_frames: list[dict] = []
        binary_count = 0
        bytes_received = 0
        terminal: Optional[dict] = None

        while True:
            try:
                raw = await self._ws.recv()
            except ConnectionClosed as e:
                if terminal is not None and terminal.get("type") == "done":
                    break
                raise DownloadError(
                    f"server closed before `done`: code={e.code} "
                    f"reason={e.reason!r}",
                    close_code=e.code,
                    reason=e.reason,
                ) from e

            if isinstance(raw, (bytes, bytearray)):
                chunks.append(bytes(raw))
                binary_count += 1
                bytes_received += len(raw)
                if progress is not None:
                    # Server streams with no known length; report
                    # bytes-so-far with total -1 (unknown).
                    try:
                        progress(bytes_received, -1)
                    except Exception:  # noqa: BLE001
                        pass
                continue

            kind, body = parse_server_frame(raw)
            if kind is ServerFrameKind.ERROR:
                raise DownloadError(
                    f"server error: {body.get('reason') or body.get('message') or ''}",
                    reason=str(body.get("reason") or body.get("message") or ""),
                )
            if kind is ServerFrameKind.DONE:
                terminal = body
                break
            # otherwise: per-AU stats frame
            stats_frames.append(body)

        assert terminal is not None  # guarded above
        return DownloadResult(
            container_uri=str(terminal.get("container_uri") or container_uri),
            payload=b"".join(chunks),
            stats_frames=stats_frames,
            binary_frame_count=binary_count,
            terminal_frame=terminal,
        )
