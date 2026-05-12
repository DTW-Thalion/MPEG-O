"""Tests for :class:`ttio.transport.ingest.TransportIngest`.

Cross-language parity with ``objc/Tests/TestTransportIngest.m``. The
6 scenarios mirror the ObjC tests packet-for-packet so a fix to one
ingest implementation that breaks parity will fail here too.

Scenarios:
  - Whole-stream feed → all packets delivered + EOS callback fires
  - Byte-by-byte feed → identical packet count + ordering
  - 7-byte chunked feed → identical (boundary-straddling)
  - Bad magic at start → ``on_error`` fires + ``feed`` raises
  - Truncated finish (header without payload) → ``finish`` raises
  - Missing StreamHeader (AU first) → rejected with proper message

The streams are crafted by hand via :class:`PacketHeader.to_bytes`
so the test stays scoped to ingest streaming behaviour, not the
full dataset/writer pipeline (covered in ``test_transport_codec.py``).
"""
from __future__ import annotations

import struct

import pytest

from ttio.transport.ingest import (
    PacketRecord,
    TransportIngest,
    TransportIngestError,
)
from ttio.transport.packets import (
    PacketFlag,
    PacketHeader,
    PacketType,
    crc32c,
)


# ---------------------------------------------------------- crafting


def _craft_packet(
    *,
    packet_type: PacketType,
    flags: int,
    dataset_id: int,
    au_sequence: int,
    payload: bytes,
) -> bytes:
    header = PacketHeader(
        packet_type=int(packet_type),
        flags=flags,
        dataset_id=dataset_id,
        au_sequence=au_sequence,
        payload_length=len(payload),
        timestamp_ns=0,
    )
    out = header.to_bytes() + payload
    if flags & int(PacketFlag.HAS_CHECKSUM):
        out += struct.pack("<I", crc32c(payload))
    return out


def _craft_sample_stream() -> bytes:
    """Minimal valid stream: StreamHeader + 3 AU + EndOfStream, all
    with HAS_CHECKSUM so the ingest exercises that path."""
    flags = int(PacketFlag.HAS_CHECKSUM)
    out = bytearray()
    out += _craft_packet(
        packet_type=PacketType.STREAM_HEADER,
        flags=flags,
        dataset_id=0,
        au_sequence=0,
        payload=b"v0",
    )
    for i in range(1, 4):
        out += _craft_packet(
            packet_type=PacketType.ACCESS_UNIT,
            flags=flags,
            dataset_id=1,
            au_sequence=i,
            payload=f"au-{i}-payload".encode("utf-8"),
        )
    out += _craft_packet(
        packet_type=PacketType.END_OF_STREAM,
        flags=flags,
        dataset_id=0,
        au_sequence=0,
        payload=b"",
    )
    return bytes(out)


# ---------------------------------------------------------- recorder


class _Recorder:
    def __init__(self) -> None:
        self.packets: list[PacketRecord] = []
        self.eos_fired = False
        self.failure: TransportIngestError | None = None

    def on_packet(self, rec: PacketRecord) -> None:
        self.packets.append(rec)

    def on_eos(self) -> None:
        self.eos_fired = True

    def on_error(self, err: TransportIngestError) -> None:
        self.failure = err


def _new_ingest() -> tuple[TransportIngest, _Recorder]:
    rec = _Recorder()
    ingest = TransportIngest(
        on_packet=rec.on_packet,
        on_end_of_stream=rec.on_eos,
        on_error=rec.on_error,
    )
    return ingest, rec


# ---------------------------------------------------------- tests


def test_whole_stream_feed():
    ingest, rec = _new_ingest()
    ingest.feed(_craft_sample_stream())

    assert len(rec.packets) == 5, "StreamHeader + 3 AU + EndOfStream"
    assert rec.eos_fired
    assert ingest.is_finished
    assert ingest.packet_count == 5
    assert rec.failure is None


def test_byte_by_byte_feed():
    stream = _craft_sample_stream()
    ingest, rec = _new_ingest()
    for byte in stream:
        ingest.feed(bytes([byte]))

    assert len(rec.packets) == 5
    assert rec.eos_fired
    assert ingest.packet_count == 5
    assert rec.failure is None


def test_chunked_feed_7_bytes():
    """7-byte chunks straddle most packet boundaries, so this
    exercises the rolling-buffer drain logic more thoroughly than
    byte-by-byte."""
    stream = _craft_sample_stream()
    ingest, rec = _new_ingest()
    for offset in range(0, len(stream), 7):
        ingest.feed(stream[offset:offset + 7])

    assert len(rec.packets) == 5
    assert rec.eos_fired


def test_bad_magic_fails():
    garbage = b"XX" + b"\x01" + b"\x00" * 21  # 24 bytes, wrong magic
    ingest, rec = _new_ingest()

    with pytest.raises(TransportIngestError):
        ingest.feed(garbage)
    assert rec.failure is not None
    assert ingest.is_finished


def test_truncated_finish_fails():
    """Feed only the StreamHeader's header bytes (advertising a
    16-byte payload that never arrives) then call finish — should
    raise with a truncated-buffer message."""
    header = PacketHeader(
        packet_type=int(PacketType.STREAM_HEADER),
        flags=0,
        dataset_id=0,
        au_sequence=0,
        payload_length=16,
        timestamp_ns=0,
    )
    ingest, rec = _new_ingest()
    ingest.feed(header.to_bytes())

    assert ingest.packet_count == 0
    assert ingest.buffered_bytes == 24

    with pytest.raises(TransportIngestError, match="partial packet"):
        ingest.finish()
    assert rec.failure is not None


def test_truncated_finish_with_empty_buffer_also_fails():
    """A producer that closes the stream without ever sending an
    EndOfStream packet is still truncated."""
    ingest, rec = _new_ingest()
    with pytest.raises(TransportIngestError, match="without EndOfStream"):
        ingest.finish()
    assert rec.failure is not None


def test_missing_stream_header_fails():
    au = _craft_packet(
        packet_type=PacketType.ACCESS_UNIT,
        flags=int(PacketFlag.HAS_CHECKSUM),
        dataset_id=1,
        au_sequence=1,
        payload=b"orphan",
    )
    ingest, rec = _new_ingest()

    with pytest.raises(TransportIngestError, match="StreamHeader"):
        ingest.feed(au)
    assert rec.failure is not None


def test_feed_after_finished_raises():
    ingest, _rec = _new_ingest()
    ingest.feed(_craft_sample_stream())
    assert ingest.is_finished
    with pytest.raises(TransportIngestError, match="finished"):
        ingest.feed(b"more")


def test_crc_mismatch_fails():
    """Flip a payload byte so the trailing CRC no longer matches."""
    stream = bytearray(_craft_sample_stream())
    # The first packet is the StreamHeader with HAS_CHECKSUM set; its
    # payload is 2 bytes ("v0") starting at byte 24. Corrupt the
    # payload (not the CRC) so the advertised CRC mismatches.
    stream[24] ^= 0xFF
    ingest, rec = _new_ingest()
    with pytest.raises(TransportIngestError, match="CRC-32C"):
        ingest.feed(bytes(stream))
    assert rec.failure is not None


def test_au_sequence_regression_fails():
    """Two AUs with non-monotonic au_sequence values should be
    rejected when the second one parses."""
    flags = int(PacketFlag.HAS_CHECKSUM)
    out = bytearray()
    out += _craft_packet(
        packet_type=PacketType.STREAM_HEADER,
        flags=flags, dataset_id=0, au_sequence=0, payload=b"v0",
    )
    out += _craft_packet(
        packet_type=PacketType.ACCESS_UNIT,
        flags=flags, dataset_id=1, au_sequence=5, payload=b"a",
    )
    out += _craft_packet(
        packet_type=PacketType.ACCESS_UNIT,
        flags=flags, dataset_id=1, au_sequence=3, payload=b"b",
    )

    ingest, rec = _new_ingest()
    with pytest.raises(TransportIngestError, match="regressed"):
        ingest.feed(bytes(out))
    assert rec.failure is not None
