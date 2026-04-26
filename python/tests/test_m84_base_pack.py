"""M84 — Clean-room BASE_PACK genomic-sequence codec.

Round-trip + canonical-vector + malformed-input + throughput tests
for the BASE_PACK 2-bit packer + sidecar mask implemented in
``ttio.codecs.base_pack``. The four canonical fixtures in
``tests/fixtures/codecs/base_pack_{a,b,c,d}.bin`` are the
cross-language conformance contract — the ObjC and Java ports must
produce byte-exact identical outputs for the same inputs.

Spec of record: ``HANDOFF.md`` M84 §1, §2, §3, §7, §8.1.
"""
from __future__ import annotations

import hashlib
import struct
import time
from pathlib import Path

import pytest

from ttio.codecs.base_pack import HEADER_LEN, MASK_ENTRY_LEN, decode, encode

FIXTURE_DIR = Path(__file__).parent / "fixtures" / "codecs"


# ── Canonical test vectors (HANDOFF.md M84 §7) ──────────────────────


def _vector_a() -> bytes:
    """Vector A — pure ACGT, 256 bytes derived from SHA-256 seed."""
    seed = hashlib.sha256(b"ttio-base-pack-vector-a").digest()
    acgt = b"ACGT"
    return bytes(acgt[b & 0b11] for b in seed * 8)


def _vector_b() -> bytes:
    """Vector B — realistic 1024-byte read with ~1% N at every 100th position."""
    seed = hashlib.sha256(b"ttio-base-pack-vector-b").digest()
    acgt = b"ACGT"
    out = bytearray()
    for i in range(1024):
        if i % 100 == 0:
            out.append(ord("N"))
        else:
            bit_pair = (seed[i % 32] >> ((i // 32) % 4 * 2)) & 0b11
            out.append(acgt[bit_pair])
    return bytes(out)


def _vector_c() -> bytes:
    """Vector C — IUPAC + soft-mask stress, exactly 64 bytes."""
    data = (
        b"ACGT"           # 0-3   plain ACGT (packed)
        b"acgt"           # 4-7   soft-mask (lowercase)
        b"NNNN"           # 8-11  all-N
        b"RYSW"           # 12-15 IUPAC
        b"KMBD"           # 16-19 IUPAC
        b"HVN-"           # 20-23 IUPAC + N + gap
        b"....AC..GT.."   # 24-35 gap + ACGT mix
        + b"ACGT" * 7     # 36-63 plain ACGT padding
    )
    assert len(data) == 64
    return data


def _vector_d() -> bytes:
    """Vector D — empty input."""
    return b""


# ── Round-trip tests (1–7) ──────────────────────────────────────────


def test_01_roundtrip_pure_acgt_1mb() -> None:
    """1 MB pure ACGT — byte-exact, no mask, total = 13 + 262144 = 262157."""
    data = b"ACGT" * 262144
    assert len(data) == 1 << 20
    enc = encode(data)
    assert len(enc) == 13 + 262144
    assert len(enc) == 262157
    # Header: version=0, orig=2^20, packed=2^18, mask_count=0
    version, orig_len, packed_len, mask_count = struct.unpack(">BIII", enc[:13])
    assert version == 0
    assert orig_len == 1 << 20
    assert packed_len == 1 << 18
    assert mask_count == 0
    assert decode(enc) == data


def test_02_roundtrip_realistic_1mb_n_every_100() -> None:
    """1 MiB ACGT with N at every 100th position — byte-exact.

    mask_count = number of multiples of 100 in ``[0, 2^20)`` = 10486
    (HANDOFF.md's §8.1 figure of 10 000 was wrong arithmetic; the
    invariant we care about is ``ceil(n/100)``).
    """
    n = 1 << 20
    data = bytearray()
    for i in range(n):
        if i % 100 == 0:
            data.append(ord("N"))
        else:
            data.append(b"ACGT"[i % 4])
    data = bytes(data)
    enc = encode(data)
    _, orig_len, packed_len, mask_count = struct.unpack(">BIII", enc[:13])
    assert orig_len == n
    assert packed_len == n // 4
    expected_mask_count = (n + 99) // 100  # ceil(n / 100)
    assert mask_count == expected_mask_count == 10486
    assert decode(enc) == data


def test_03_roundtrip_all_n_1mb() -> None:
    """1 MiB all-N — byte-exact; size = 13 + 2^18 + 5·2^20 = 5,505,037."""
    n = 1 << 20
    data = b"N" * n
    enc = encode(data)
    _, orig_len, packed_len, mask_count = struct.unpack(">BIII", enc[:13])
    assert orig_len == n
    assert packed_len == n // 4
    assert mask_count == n
    # Body byte for an all-N stream is the placeholder 0x00.
    assert enc[13] == 0x00
    expected = HEADER_LEN + n // 4 + MASK_ENTRY_LEN * n
    assert len(enc) == expected
    assert len(enc) == 5_505_037  # 13 + 262144 + 5*1048576
    assert decode(enc) == data


def test_04_roundtrip_empty() -> None:
    """Empty input — byte-exact, header only (13 bytes)."""
    enc = encode(b"")
    assert len(enc) == 13
    assert enc == bytes.fromhex("00" + "00000000" * 3)
    assert decode(enc) == b""


def test_05_roundtrip_single_acgt_and_padding_tails() -> None:
    """Single ACGT bases plus 2- and 3-byte padding-tail patterns (Gotcha §94)."""
    expected_body = {
        b"A": 0x00,
        b"C": 0x40,
        b"G": 0x80,
        b"T": 0xC0,
    }
    for ch, body in expected_body.items():
        enc = encode(ch)
        assert len(enc) == 14, f"{ch!r}: len {len(enc)} != 14"
        # Header: orig=1, packed=1, mask_count=0
        version, orig_len, packed_len, mask_count = struct.unpack(">BIII", enc[:13])
        assert (version, orig_len, packed_len, mask_count) == (0, 1, 1, 0)
        assert enc[13] == body, f"{ch!r}: body 0x{enc[13]:02x} != 0x{body:02x}"
        assert decode(enc) == ch
    # 2-base tail: AC -> 0x10
    enc = encode(b"AC")
    assert len(enc) == 14
    assert enc[13] == 0x10
    assert decode(enc) == b"AC"
    # 3-base tail: ACG -> 0x18
    enc = encode(b"ACG")
    assert len(enc) == 14
    assert enc[13] == 0x18
    assert decode(enc) == b"ACG"


def test_06_roundtrip_single_n() -> None:
    """Single N — byte-exact, total = 13 + 1 + 5 = 19."""
    enc = encode(b"N")
    assert len(enc) == 19
    _, orig_len, packed_len, mask_count = struct.unpack(">BIII", enc[:13])
    assert (orig_len, packed_len, mask_count) == (1, 1, 1)
    # Body is placeholder 0x00; mask entry: position 0, byte 'N' (0x4E).
    assert enc[13] == 0x00
    assert enc[14:] == struct.pack(">IB", 0, ord("N"))
    assert decode(enc) == b"N"


def test_07_iupac_stress_alphabet() -> None:
    """IUPAC + soft-mask + gap full alphabet — mask_count = 17 (positions 4–20)."""
    data = b"ACGTacgtNRYSWKMBDHV-."
    assert len(data) == 21
    enc = encode(data)
    _, orig_len, packed_len, mask_count = struct.unpack(">BIII", enc[:13])
    assert orig_len == 21
    assert packed_len == 6  # ceil(21 / 4)
    assert mask_count == 17  # positions 4..20 inclusive
    assert decode(enc) == data
    # Verify mask positions are exactly 4..20 in order.
    mask_off = 13 + 6
    positions = [
        struct.unpack(">I", enc[mask_off + i * 5 : mask_off + i * 5 + 4])[0]
        for i in range(17)
    ]
    assert positions == list(range(4, 21))


# ── Canonical-vector fixture conformance (8–11) ─────────────────────


def _load_fixture(name: str) -> bytes:
    return (FIXTURE_DIR / f"base_pack_{name}.bin").read_bytes()


def test_08_canonical_vector_a() -> None:
    """Vector A encodes byte-exact to base_pack_a.bin (77 bytes, no mask)."""
    data = _vector_a()
    enc = encode(data)
    fixture = _load_fixture("a")
    assert len(fixture) == 77
    assert enc == fixture
    assert decode(fixture) == data


def test_09_canonical_vector_b() -> None:
    """Vector B encodes byte-exact to base_pack_b.bin (324 bytes, mask=11)."""
    data = _vector_b()
    enc = encode(data)
    fixture = _load_fixture("b")
    assert len(fixture) == 324
    assert enc == fixture
    _, _, _, mask_count = struct.unpack(">BIII", enc[:13])
    assert mask_count == 11
    assert decode(fixture) == data


def test_10_canonical_vector_c() -> None:
    """Vector C encodes byte-exact to base_pack_c.bin (169 bytes, mask=28)."""
    data = _vector_c()
    enc = encode(data)
    fixture = _load_fixture("c")
    assert len(fixture) == 169
    assert enc == fixture
    _, _, _, mask_count = struct.unpack(">BIII", enc[:13])
    assert mask_count == 28
    assert decode(fixture) == data


def test_11_canonical_vector_d() -> None:
    """Vector D (empty) encodes byte-exact to base_pack_d.bin (13 bytes)."""
    enc = encode(_vector_d())
    fixture = _load_fixture("d")
    assert len(fixture) == 13
    assert enc == fixture
    assert decode(fixture) == b""


# ── Malformed-input rejection (12) ──────────────────────────────────


def test_12_decode_malformed_inputs() -> None:
    """Five malformed-input variants each raise ValueError."""
    # Build a known-good baseline stream we can mutate.
    data = b"ACGTNACGT"  # orig=9, packed=3, mask_count=1 (pos 4 = 'N')
    good = encode(data)
    assert decode(good) == data

    # 12a: truncated stream — strip the trailing mask entry.
    truncated = good[:-1]
    with pytest.raises(ValueError):
        decode(truncated)

    # 12b: bad version byte (0x01 instead of 0x00).
    bad_version = bytearray(good)
    bad_version[0] = 0x01
    with pytest.raises(ValueError):
        decode(bytes(bad_version))

    # 12c: packed_length mismatch — set packed_length = 999.
    bad_packed = bytearray(good)
    bad_packed[5:9] = struct.pack(">I", 999)
    with pytest.raises(ValueError):
        decode(bytes(bad_packed))

    # 12d: mask position out of range (position == orig_len).
    # Build a fresh stream where we set the single mask entry's
    # position to orig_len.
    bad_pos = bytearray(good)
    mask_offset = HEADER_LEN + 3  # packed_len = 3
    bad_pos[mask_offset : mask_offset + 4] = struct.pack(">I", 9)  # == orig_len
    with pytest.raises(ValueError):
        decode(bytes(bad_pos))

    # 12e: mask positions out of order — need a stream with two
    # mask entries; swap them so positions descend.
    data2 = b"ANCNGT"  # orig=6, packed=2, mask entries at positions 1 and 3
    good2 = encode(data2)
    _, orig_len, packed_len, mask_count = struct.unpack(">BIII", good2[:13])
    assert mask_count == 2
    mask_offset = HEADER_LEN + packed_len
    entry0 = good2[mask_offset : mask_offset + MASK_ENTRY_LEN]
    entry1 = good2[mask_offset + MASK_ENTRY_LEN : mask_offset + 2 * MASK_ENTRY_LEN]
    swapped = (
        good2[:mask_offset]
        + entry1
        + entry0
        + good2[mask_offset + 2 * MASK_ENTRY_LEN :]
    )
    with pytest.raises(ValueError):
        decode(swapped)


# ── Soft-masking round-trip (13) ────────────────────────────────────


def test_13_soft_masking_roundtrip() -> None:
    """Soft-masking (lowercase) round-trips losslessly via the mask."""
    data = b"ACGTacgtACGT"
    enc = encode(data)
    _, orig_len, packed_len, mask_count = struct.unpack(">BIII", enc[:13])
    assert orig_len == 12
    assert packed_len == 3
    assert mask_count == 4  # positions 4, 5, 6, 7 (the lowercase block)
    assert decode(enc) == data


# ── Throughput (14) ─────────────────────────────────────────────────


def test_14_throughput_pure_acgt_10mb() -> None:
    """Encode/decode 10 MB pure ACGT — log MB/s; PASS if encode ≥ 20, decode ≥ 50."""
    n = 10 * (1 << 20)
    data = b"ACGT" * (n // 4)
    assert len(data) == n

    t0 = time.perf_counter()
    enc = encode(data)
    t_enc = time.perf_counter() - t0

    t0 = time.perf_counter()
    dec = decode(enc)
    t_dec = time.perf_counter() - t0

    assert dec == data
    enc_mbps = (n / (1 << 20)) / t_enc
    dec_mbps = (n / (1 << 20)) / t_dec
    print(
        f"\n  base_pack 10 MB pure-ACGT: "
        f"encode {enc_mbps:.1f} MB/s ({t_enc*1000:.1f} ms), "
        f"decode {dec_mbps:.1f} MB/s ({t_dec*1000:.1f} ms)"
    )
    assert enc_mbps >= 20.0, f"encode throughput {enc_mbps:.1f} MB/s < 20 MB/s"
    assert dec_mbps >= 50.0, f"decode throughput {dec_mbps:.1f} MB/s < 50 MB/s"
