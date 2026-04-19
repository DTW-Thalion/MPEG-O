"""MPEG-O streaming transport codec (v0.10 M67).

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
``com.dtwthalion.mpgo.transport``.
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

__all__ = [
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
