"""M95 DELTA_RANS_ORDER0 codec unit tests."""
from __future__ import annotations

import struct

import pytest

from ttio.codecs.delta_rans import decode
from ttio.codecs.delta_rans import encode


class TestZigzagVarints:
    """Verify the internal zigzag + varint primitives."""

    def test_zigzag_round_trip(self):
        from ttio.codecs.delta_rans import _zigzag_encode, _zigzag_decode
        for val in [0, 1, -1, 2, -2, 127, -128, 300, -300, 2**31, -(2**31)]:
            assert _zigzag_decode(_zigzag_encode(val)) == val

    def test_varint_round_trip(self):
        from ttio.codecs.delta_rans import _varint_encode, _varint_decode_all
        values = [0, 1, 127, 128, 16383, 16384, 300, 500, 2**20]
        buf = bytearray()
        for v in values:
            buf.extend(_varint_encode(v))
        decoded = _varint_decode_all(bytes(buf))
        assert decoded == values


class TestDeltaRansRoundTrip:
    """Round-trip encode/decode for each element size."""

    def test_int64_sorted_ascending(self):
        values = [1000 + i * 150 for i in range(100)]
        raw = struct.pack("<100q", *values)
        encoded = encode(raw, element_size=8)
        assert encoded[:4] == b"DRA0"
        decoded = decode(encoded)
        assert decoded == raw

    def test_int32_bimodal(self):
        values = [350, -350, 351, -349, 348, -352] * 20
        raw = struct.pack("<120i", *values)
        encoded = encode(raw, element_size=4)
        decoded = decode(encoded)
        assert decoded == raw

    def test_int8(self):
        values = [10, 20, 30, 40, 50, 60]
        raw = struct.pack("<6b", *values)
        encoded = encode(raw, element_size=1)
        decoded = decode(encoded)
        assert decoded == raw

    def test_empty(self):
        encoded = encode(b"", element_size=8)
        assert encoded[:4] == b"DRA0"
        decoded = decode(encoded)
        assert decoded == b""

    def test_single_element(self):
        raw = struct.pack("<q", 42)
        encoded = encode(raw, element_size=8)
        decoded = decode(encoded)
        assert decoded == raw

    def test_negative_deltas(self):
        values = [1000, 900, 800, 700, 600]
        raw = struct.pack("<5q", *values)
        encoded = encode(raw, element_size=8)
        decoded = decode(encoded)
        assert decoded == raw


class TestDeltaRansWireFormat:
    """Verify header structure."""

    def test_header_fields(self):
        raw = struct.pack("<4q", 100, 200, 300, 400)
        encoded = encode(raw, element_size=8)
        assert encoded[0:4] == b"DRA0"
        assert encoded[4] == 1       # version
        assert encoded[5] == 8       # element_size
        assert encoded[6:8] == b"\x00\x00"  # reserved

    def test_bad_magic_rejected(self):
        raw = struct.pack("<q", 42)
        encoded = bytearray(encode(raw, element_size=8))
        encoded[0:4] = b"XXXX"
        with pytest.raises(ValueError, match="magic"):
            decode(bytes(encoded))

    def test_bad_version_rejected(self):
        raw = struct.pack("<q", 42)
        encoded = bytearray(encode(raw, element_size=8))
        encoded[4] = 99
        with pytest.raises(ValueError, match="version"):
            decode(bytes(encoded))

    def test_invalid_element_size_encode_rejected(self):
        with pytest.raises(ValueError, match="element_size"):
            encode(b"\x00" * 3, element_size=3)

    def test_invalid_element_size_decode_rejected(self):
        raw = struct.pack("<q", 42)
        encoded = bytearray(encode(raw, element_size=8))
        encoded[5] = 3
        with pytest.raises(ValueError, match="element_size"):
            decode(bytes(encoded))


import pathlib

FIXTURE_DIR = pathlib.Path(__file__).parent / "fixtures" / "codecs"


class TestFixtureRoundTrip:
    """Verify the canonical fixtures decode correctly."""

    def test_fixture_a_sorted_int64(self):
        encoded = (FIXTURE_DIR / "delta_rans_a.bin").read_bytes()
        decoded = decode(encoded)
        assert len(decoded) == 1000 * 8
        values = list(struct.unpack("<1000q", decoded))
        assert all(values[i] < values[i + 1] for i in range(999))

    def test_fixture_b_uint32_flags(self):
        encoded = (FIXTURE_DIR / "delta_rans_b.bin").read_bytes()
        decoded = decode(encoded)
        assert len(decoded) == 100 * 4
        values = list(struct.unpack("<100I", decoded))
        assert set(values) == {0, 16, 83, 99, 163}

    def test_fixture_c_empty(self):
        encoded = (FIXTURE_DIR / "delta_rans_c.bin").read_bytes()
        decoded = decode(encoded)
        assert decoded == b""

    def test_fixture_d_single(self):
        encoded = (FIXTURE_DIR / "delta_rans_d.bin").read_bytes()
        decoded = decode(encoded)
        assert struct.unpack("<q", decoded)[0] == 1234567890
