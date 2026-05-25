"""Reader tolerates unknown packet types (forward compat for v0.11).

Mirrors the Java ``TransportReaderSkipUnknownTest`` (commit 0a777019).
Task 0.5 of transport-spec v0.11.
"""
from __future__ import annotations

import io
import struct

from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import (
    HEADER_MAGIC,
    HEADER_SIZE,
    VERSION,
    PacketType,
)


def _write_raw_packet(out: io.BytesIO, type_byte: int, payload: bytes) -> None:
    """Splice a packet with an arbitrary (possibly unknown) wire type
    byte directly onto the stream — no checksum, zero flags / ids /
    timestamp. Mirrors the Java test's ``writeRawPacket`` helper.
    """
    header = struct.pack(
        "<2sBBHHIIQ",
        HEADER_MAGIC,
        VERSION,
        type_byte & 0xFF,
        0,                # flags
        0,                # dataset_id
        0,                # au_sequence
        len(payload),     # payload_length
        0,                # timestamp_ns
    )
    assert len(header) == HEADER_SIZE
    out.write(header)
    out.write(payload)


def test_unknown_packet_type_is_skipped_not_thrown():
    buf = io.BytesIO()
    w = TransportWriter(buf)
    w.write_stream_header(
        format_version="1.2",
        title="test",
        isa_investigation="",
        features=["transport_v0_11"],
        n_datasets=0,
    )

    # Manually splice in a packet whose type byte (0x7E) is not a
    # known PacketType. The reader must consume the length-prefixed
    # payload and continue past it to EndOfStream.
    payload = b"future-extension-data"
    _write_raw_packet(buf, 0x7E, payload)

    w.write_end_of_stream()

    r = TransportReader(io.BytesIO(buf.getvalue()))
    records = r.records_for_test()

    assert len(records) == 3, (
        "expected StreamHeader + unknown + EndOfStream; got " + repr(records)
    )

    skipped = records[1]
    assert skipped.header.packet_type_byte == 0x7E, (
        "raw type byte must be preserved on the header"
    )
    # Python keeps packet_type as a raw int (idiomatic vs Java's
    # nullable enum), so the equality check is on the byte.
    assert skipped.header.packet_type == 0x7E
    assert skipped.payload == payload, (
        "payload bytes were length-prefixed and copied verbatim"
    )

    assert records[0].header.packet_type == int(PacketType.STREAM_HEADER)
    assert records[2].header.packet_type == int(PacketType.END_OF_STREAM)


def test_unknown_packet_type_logged_at_debug(caplog):
    import logging
    buf = io.BytesIO()
    w = TransportWriter(buf)
    w.write_stream_header(
        format_version="1.2",
        title="test",
        isa_investigation="",
        features=["transport_v0_11"],
        n_datasets=0,
    )
    _write_raw_packet(buf, 0x7E, b"x" * 4)
    w.write_end_of_stream()

    with caplog.at_level(logging.DEBUG, logger="ttio.transport.codec"):
        TransportReader(io.BytesIO(buf.getvalue())).records_for_test()

    assert any("0x7e" in r.getMessage().lower() for r in caplog.records), (
        "expected a debug log mentioning the unknown type byte 0x7E"
    )
