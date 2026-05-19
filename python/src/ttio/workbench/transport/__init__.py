"""
ttio.workbench.transport -- workbench-aware WebSocket transport.

Speaks the `ttio-transport` WS subprotocol against
`tti-workbench-server` v1.0.0+. Wire contract:

  - `wss://<host>:<port>/transport` (or `ws://` for development)
  - First frame: TEXT, JSON, `{"type":"handshake", ...}` with
    `owner` + `project` + `container_uri` (upload) or
    `mode:"download"` + `container_uri` + optional `filter` /
    `output_mode` / `max_au` (download).
  - Server ack: TEXT, JSON, `{"type":"ack","handle":...,"au_sequence":N}`.
  - Upload payload: BINARY frames carrying raw `.tis` bytes; framing
    is byte-agnostic (per spec section 9.2 / Documentation/upload-protocol.md).
  - Per-AU acks during upload (TEXT JSON `{"type":"ack","au_sequence":N}`).
  - Terminal frame: `{"type":"done","container_uri":...}` (upload) or
    `{"type":"done", ...}` (download), then WS close 1000.
  - Error path: `{"type":"error","message":...}` (upload) /
    `{"type":"error","reason":...}` (download), then WS close 1002 / 1011.
  - Resume: client sends `resume_handle:"stg-..."` in a fresh
    handshake; server replies with the persisted `au_sequence` so
    the client can skip already-acked AUs.

Exposed types:

  - `UploadClient` / `DownloadClient` -- async context managers.
  - `build_upload_handshake` / `build_download_handshake` -- pure
    JSON builders (no I/O), reused by the Java port + tests.
  - `ResumeState` -- carries the `resume_handle` + last acked
    sequence between attempts.

The synthetic-payload helper from `ttio.transport.simulator` works
unchanged as an UploadClient payload source (UC-01 "Local Encoding"
in the spec is satisfied by `ttio encode`; the transport layer
doesn't care where the bytes came from).
"""

from ttio.workbench.transport.handshake import (
    build_download_handshake,
    build_upload_handshake,
    parse_server_frame,
    ServerFrameKind,
)
from ttio.workbench.transport.resume import ResumeState
from ttio.workbench.transport.upload import UploadClient, UploadResult
from ttio.workbench.transport.download import (
    DownloadClient,
    DownloadResult,
    FilterDict,
    OutputMode,
)
from ttio.workbench.transport.errors import (
    HandshakeError,
    UploadError,
    DownloadError,
    TransportError,
)

__all__ = [
    "build_download_handshake",
    "build_upload_handshake",
    "parse_server_frame",
    "ServerFrameKind",
    "ResumeState",
    "UploadClient",
    "UploadResult",
    "DownloadClient",
    "DownloadResult",
    "FilterDict",
    "OutputMode",
    "HandshakeError",
    "UploadError",
    "DownloadError",
    "TransportError",
]
