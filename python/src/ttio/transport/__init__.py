"""TTI-O streaming transport codec (v0.10 M67).

Implements the wire format specified in ``docs/transport-spec.md``:

- :class:`PacketHeader` — 24-byte fixed header with CRC-32C checksum
  support.
- :class:`PacketType` — enum of 9 packet types (stream/dataset header,
  access unit, protection metadata, annotation, provenance,
  chromatogram, end-of-dataset, end-of-stream).
- :class:`AccessUnit` — one spectrum's filter keys + channel bytes.
- :class:`TransportWriter` / :class:`TransportReader` — file and
  in-memory stream codecs.
- :func:`file_to_transport` / :func:`transport_to_file` — convenience
  one-shot round-trip helpers.

Cross-language: ObjC ``objc/Source/Transport/`` · Java
``com.dtwthalion.ttio.transport``.
"""
from __future__ import annotations

from .packets import (
    HEADER_MAGIC,
    HEADER_SIZE,
    VERSION,
    AccessUnit,
    ChannelData,
    PacketFlag,
    PacketHeader,
    PacketType,
    crc32c,
)
from .codec import (
    TransportReader,
    TransportWriter,
    file_to_transport,
    transport_to_file,
)
from .filters import AUFilter

__all__ = [
    "AUFilter",
    "HEADER_MAGIC",
    "HEADER_SIZE",
    "VERSION",
    "AccessUnit",
    "ChannelData",
    "PacketFlag",
    "PacketHeader",
    "PacketType",
    "TransportReader",
    "TransportWriter",
    "crc32c",
    "file_to_transport",
    "transport_to_file",
]


def __getattr__(name: str):
    # v0.10 M68: lazy re-export of server / client so importing
    # ``ttio.transport`` works without ``websockets`` installed.
    if name in ("TransportServer", "serving"):
        from .server import TransportServer, serving
        return {"TransportServer": TransportServer, "serving": serving}[name]
    if name == "TransportClient":
        from .client import TransportClient
        return TransportClient
    raise AttributeError(f"module 'ttio.transport' has no attribute {name!r}")
