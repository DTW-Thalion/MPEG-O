"""M85 Phase A — Clean-room QUALITY_BINNED genomic-quality codec.

Round-trip + canonical-vector + malformed-input + throughput tests
for the QUALITY_BINNED 8-bin Phred quantiser + 4-bit packer
implemented in ``ttio.codecs.quality``. The four canonical fixtures
in ``tests/fixtures/codecs/quality_{a,b,c,d}.bin`` are the
cross-language conformance contract — the ObjC and Java ports must
produce byte-exact identical outputs for the same inputs.

Spec of record: ``HANDOFF.md`` M85 Phase A §1, §2, §3, §7, §8.
"""
from __future__ import annotations

import hashlib
import os
import struct
import time
from pathlib import Path

import pytest

from ttio.codecs.quality import HEADER_LEN, SCHEME_ILLUMINA_8, VERSION, decode, encode

FIXTURE_DIR = Path(__file__).parent / "fixtures" / "codecs"


# ── Reference bin / centre tables (kept independent of the codec) ──
#
# These mirror the spec in HANDOFF.md §2 and are used only for the
# expected-value computation in the lossy round-trip tests. They
# must NOT import from the codec module — the point is to check the
# implementation against an independent restatement of the table.

_BIN_OF = (
    [0] * 2          # 0..1
    + [1] * 8        # 2..9
    + [2] * 10       # 10..19
    + [3] * 5        # 20..24
    + [4] * 5        # 25..29
    + [5] * 5        # 30..34
    + [6] * 5        # 35..39
    + [7] * (256 - 40)  # 40..255
)
assert len(_BIN_OF) == 256

_CENTRE = (0, 5, 15, 22, 27, 32, 37, 40)


def _lossy_expected(data: bytes) -> bytes:
    """Map each input byte through bin-of → centre to compute the
    expected lossy round-trip output."""
    return bytes(_CENTRE[_BIN_OF[b]] for b in data)


# ── Canonical test vectors (HANDOFF.md M85 §8) ─────────────────────


def _vector_a() -> bytes:
    """Vector A — 256 bytes of pure bin centres (4 cycles × 8 × 8)."""
    return bytes([0, 5, 15, 22, 27, 32, 37, 40]) * 32


def _vector_b() -> bytes:
    """Vector B — 1024 bytes Illumina-realistic Phred profile, SHA-256 seeded."""
    seed = hashlib.sha256(b"ttio-quality-vector-b").digest()
    out = bytearray()
    for i in range(1024):
        if i < 512:
            base = 30 + (seed[i % 32] % 11)
        else:
            base = 15 + (seed[i % 32] % 16)
        out.append(base)
    return bytes(out)


def _vector_c() -> bytes:
    """Vector C — 64 bytes hand-picked edge cases (every bin boundary + saturation)."""
    data = bytes([
        0,  1,
        2,  5,  9,
        10, 15, 19,
        20, 22, 24,
        25, 27, 29,
        30, 32, 34,
        35, 37, 39,
        40, 41, 50, 60, 93, 100, 200, 255,
        0, 5, 15, 22, 27, 32, 37, 40,
        0, 5, 15, 22, 27, 32, 37, 40,
        0, 5, 15, 22, 27, 32, 37, 40,
        0, 5, 15, 22, 27, 32, 37, 40,
        0, 5, 15, 22,
    ])
    assert len(data) == 64
    return data


def _vector_d() -> bytes:
    """Vector D — empty input."""
    return b""


def _load_fixture(name: str) -> bytes:
    return (FIXTURE_DIR / f"quality_{name}.bin").read_bytes()


# ── Round-trip tests (1–7) ─────────────────────────────────────────


def test_01_round_trip_pure_centre_bytes() -> None:
    """256 bytes of pure bin centres round-trip byte-exact (no info lost)."""
    data = bytes([0, 5, 15, 22, 27, 32, 37, 40]) * 32
    assert len(data) == 256
    enc = encode(data)
    assert len(enc) == 6 + 128
    assert decode(enc) == data  # byte-exact when all inputs are centres


def test_02_round_trip_arbitrary_phred() -> None:
    """50 bytes 0..49 round-trip via the lossy centre mapping."""
    data = bytes(range(50))
    expected = _lossy_expected(data)
    # Sanity-check a few hand-computed entries:
    # 0 -> bin 0 -> centre 0; 7 -> bin 1 -> centre 5;
    # 19 -> bin 2 -> centre 15; 24 -> bin 3 -> centre 22;
    # 40 -> bin 7 -> centre 40; 49 -> bin 7 -> centre 40.
    assert expected[0] == 0
    assert expected[7] == 5
    assert expected[19] == 15
    assert expected[24] == 22
    assert expected[40] == 40
    assert expected[49] == 40
    assert decode(encode(data)) == expected


def test_03_round_trip_clamped() -> None:
    """Phred 41+ all map to bin 7 / centre 40."""
    data = bytes([50, 60, 93, 100, 200, 255])
    expected = bytes([40] * 6)
    assert _lossy_expected(data) == expected
    assert decode(encode(data)) == expected


def test_04_round_trip_empty() -> None:
    """Empty input → 6-byte header → empty output."""
    enc = encode(b"")
    assert len(enc) == 6
    # Header: version=0, scheme_id=0, orig_len=0
    assert enc == bytes.fromhex("0000" + "00000000")
    version, scheme_id, orig_len = struct.unpack(">BBI", enc)
    assert version == VERSION == 0
    assert scheme_id == SCHEME_ILLUMINA_8 == 0
    assert orig_len == 0
    assert decode(enc) == b""


def test_05_round_trip_single_byte() -> None:
    """Each bin-centre Phred value round-trips to itself in a 7-byte stream."""
    centres_and_bins = [
        (0, 0),
        (5, 1),
        (15, 2),
        (22, 3),
        (27, 4),
        (32, 5),
        (37, 6),
        (40, 7),
    ]
    for centre, bin_idx in centres_and_bins:
        enc = encode(bytes([centre]))
        assert len(enc) == 7, f"centre={centre}: expected 7-byte stream"
        # Header: version=0, scheme=0, orig_len=1
        version, scheme_id, orig_len = struct.unpack(">BBI", enc[:6])
        assert (version, scheme_id, orig_len) == (0, 0, 1)
        # Body byte: bin_idx in high nibble, padding zero in low nibble.
        assert enc[6] == (bin_idx << 4), (
            f"centre={centre}: body 0x{enc[6]:02x} != 0x{(bin_idx << 4):02x}"
        )
        # Round-trip: bin centre is fixed point.
        assert decode(enc) == bytes([centre])


def test_06_padding_tail_patterns() -> None:
    """1-, 2-, 3-, 4-byte inputs verify the high-nibble + zero-padding behaviour."""
    # 1 byte, value 0 (bin 0): body = 0x00 (nothing in either nibble).
    enc = encode(b"\x00")
    assert len(enc) == 7
    assert enc[6] == 0x00
    assert decode(enc) == b"\x00"

    # 1 byte, value 5 (bin 1): body = 0x10 — bin 1 in high nibble,
    # zero padding in low nibble (binding decision §96).
    enc = encode(b"\x05")
    assert len(enc) == 7
    assert enc[6] == 0x10
    assert decode(enc) == b"\x05"

    # 2 bytes, values 5,5 (bins 1,1): body = 0x11 — no padding.
    enc = encode(b"\x05\x05")
    assert len(enc) == 7  # 6 header + 1 body
    assert enc[6] == 0x11
    assert decode(enc) == b"\x05\x05"

    # 3 bytes, values 5,5,5 (bins 1,1,1): body = 0x11 0x10 — second
    # body byte has bin 1 in high nibble, zero padding in low.
    enc = encode(b"\x05\x05\x05")
    assert len(enc) == 8  # 6 header + 2 body
    assert enc[6] == 0x11
    assert enc[7] == 0x10
    assert decode(enc) == b"\x05\x05\x05"

    # 4 bytes, values 5,5,5,5: body = 0x11 0x11 — no padding.
    enc = encode(b"\x05\x05\x05\x05")
    assert len(enc) == 8  # 6 header + 2 body
    assert enc[6] == 0x11
    assert enc[7] == 0x11
    assert decode(enc) == b"\x05\x05\x05\x05"


def test_07_compression_ratio() -> None:
    """1 MiB of arbitrary Phred bytes packs to exactly 6 + ceil(n/2) bytes."""
    n = 1024 * 1024
    data = bytes((b % 41) for b in os.urandom(n))
    enc = encode(data)
    expected_size = 6 + (n + 1) // 2
    assert len(enc) == expected_size
    # Body is exactly half the input size; total is just over 50%.
    assert len(enc) - HEADER_LEN == n // 2
    # Decode yields the lossy expected mapping.
    assert decode(enc) == _lossy_expected(data)


# ── Canonical-vector fixture conformance (8–11) ────────────────────


def test_08_canonical_vector_a() -> None:
    """Vector A encodes byte-exact to quality_a.bin (134 bytes)."""
    data = _vector_a()
    enc = encode(data)
    fixture = _load_fixture("a")
    assert len(fixture) == 134
    assert enc == fixture
    # Lossy round-trip: bin centres are fixed points → byte-exact.
    assert decode(fixture) == data


def test_09_canonical_vector_b() -> None:
    """Vector B encodes byte-exact to quality_b.bin (518 bytes)."""
    data = _vector_b()
    enc = encode(data)
    fixture = _load_fixture("b")
    assert len(fixture) == 518
    assert enc == fixture
    assert decode(fixture) == _lossy_expected(data)


def test_10_canonical_vector_c() -> None:
    """Vector C encodes byte-exact to quality_c.bin (38 bytes)."""
    data = _vector_c()
    enc = encode(data)
    fixture = _load_fixture("c")
    assert len(fixture) == 38
    assert enc == fixture
    assert decode(fixture) == _lossy_expected(data)


def test_11_canonical_vector_d() -> None:
    """Vector D (empty) encodes byte-exact to quality_d.bin (6 bytes)."""
    enc = encode(_vector_d())
    fixture = _load_fixture("d")
    assert len(fixture) == 6
    assert enc == fixture
    assert decode(fixture) == b""


# ── Malformed-input rejection (12) ─────────────────────────────────


def test_12_decode_malformed() -> None:
    """Five malformed-input variants each raise ValueError."""
    # Build a known-good baseline stream: orig_len=4, body=2 bytes.
    data = b"\x05\x05\x05\x05"
    good = encode(data)
    assert len(good) == 8  # 6 header + 2 body
    assert decode(good) == data

    # 12a: stream shorter than the 6-byte header (e.g., 3 bytes).
    with pytest.raises(ValueError, match="too short"):
        decode(b"\x00\x00\x00")

    # 12b: bad version byte (0x01 instead of 0x00).
    bad_version = bytearray(good)
    bad_version[0] = 0x01
    with pytest.raises(ValueError, match="bad version"):
        decode(bytes(bad_version))

    # 12c: bad scheme_id (0xFF instead of 0x00).
    bad_scheme = bytearray(good)
    bad_scheme[1] = 0xFF
    with pytest.raises(ValueError, match="scheme_id"):
        decode(bytes(bad_scheme))

    # 12d: original_length says 4 but body is 5 bytes (length mismatch).
    # Header says orig=4 → expected body = 2. We feed it a 5-byte body.
    bad_long = struct.pack(">BBI", 0, 0, 4) + b"\x11\x11\x11\x11\x11"
    with pytest.raises(ValueError, match="length mismatch"):
        decode(bad_long)

    # 12e: original_length says 5 but body is only 2 bytes (truncation).
    # orig=5 → expected body = ceil(5/2) = 3. We feed it 2 body bytes.
    bad_short = struct.pack(">BBI", 0, 0, 5) + b"\x11\x10"
    with pytest.raises(ValueError, match="length mismatch"):
        decode(bad_short)


# ── Throughput (13) ────────────────────────────────────────────────


def test_13_throughput() -> None:
    """Encode/decode 10 MiB — log MB/s; PASS if encode ≥ 50, decode ≥ 100."""
    n = 10 * 1024 * 1024
    data = bytes((b % 41) for b in os.urandom(n))

    t0 = time.perf_counter()
    enc = encode(data)
    t_enc = time.perf_counter() - t0

    t0 = time.perf_counter()
    dec = decode(enc)
    t_dec = time.perf_counter() - t0

    assert dec == _lossy_expected(data)

    enc_mbps = (n / (1024 * 1024)) / t_enc
    dec_mbps = (n / (1024 * 1024)) / t_dec
    print(
        f"\n  quality_binned 10 MiB: "
        f"encode {enc_mbps:.1f} MB/s ({t_enc*1000:.1f} ms), "
        f"decode {dec_mbps:.1f} MB/s ({t_dec*1000:.1f} ms)"
    )
    assert enc_mbps >= 50.0, f"encode throughput {enc_mbps:.1f} MB/s < 50 MB/s"
    assert dec_mbps >= 100.0, f"decode throughput {dec_mbps:.1f} MB/s < 100 MB/s"
