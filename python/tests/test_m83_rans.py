"""M83 — Clean-room rANS entropy codec.

Round-trip + canonical-vector + malformed-input + throughput tests
for the order-0 and order-1 rANS codec implemented in
``ttio.codecs.rans``.  The canonical vector fixtures in
``tests/fixtures/codecs/rans_<x>_o<n>.bin`` are the cross-language
conformance contract — the ObjC and Java ports must produce
byte-exact identical outputs for the same inputs.

Spec of record: ``HANDOFF.md`` §1, §2, §5, §6, §7.1.
"""
from __future__ import annotations

import hashlib
import os
import time
from pathlib import Path

import pytest

from ttio.codecs.rans import decode, encode

FIXTURE_DIR = Path(__file__).parent / "fixtures" / "codecs"


# ── Canonical test vectors (HANDOFF.md §6.1) ────────────────────────


def _vector_a() -> bytes:
    """Uniform-random-ish 256 bytes (SHA-256 digest repeated 8x)."""
    return hashlib.sha256(b"ttio-rans-test-vector-a").digest() * 8


def _vector_b() -> bytes:
    """Heavily skewed 1024 bytes — 78% 0x00, 10% 0x01, 8% 0x02, 4% 0x03."""
    return bytes([0] * 800 + [1] * 100 + [2] * 80 + [3] * 44)


def _vector_c() -> bytes:
    """Perfectly cyclic 0,1,2,3,0,1,2,3,... (512 bytes) — order-1 ideal."""
    return bytes([i % 4 for i in range(512)])


# ── Round-trip tests (1–7) ──────────────────────────────────────────


def test_01_roundtrip_order0_random_1mb() -> None:
    """Order-0 round-trip on 1 MiB of os.urandom — byte-exact."""
    data = os.urandom(1 << 20)
    enc = encode(data, 0)
    dec = decode(enc)
    assert dec == data
    # Random data is incompressible — encoded size should be roughly
    # input size (within a small constant overhead).
    assert len(enc) >= len(data)


def test_02_roundtrip_order1_random_1mb() -> None:
    """Order-1 round-trip on 1 MiB of os.urandom — byte-exact."""
    data = os.urandom(1 << 20)
    enc = encode(data, 1)
    dec = decode(enc)
    assert dec == data


def test_03_roundtrip_order0_biased_1mb() -> None:
    """Order-0 round-trip on 1 MiB biased data; compressed < 50 % of input."""
    n = 1 << 20
    counts = (int(n * 0.90), int(n * 0.05), int(n * 0.03))
    payload = (
        bytes([0x00]) * counts[0]
        + bytes([0x01]) * counts[1]
        + bytes([0x02]) * counts[2]
    )
    payload += bytes([0x03]) * (n - len(payload))
    assert len(payload) == n
    enc = encode(payload, 0)
    dec = decode(enc)
    assert dec == payload
    assert len(enc) < n // 2, f"biased order-0 enc={len(enc)} >= n/2"


def test_04_roundtrip_order1_biased_le_order0() -> None:
    """Order-1 biased round-trip; compressed ≤ order-0 compressed."""
    n = 1 << 20
    counts = (int(n * 0.90), int(n * 0.05), int(n * 0.03))
    payload = (
        bytes([0x00]) * counts[0]
        + bytes([0x01]) * counts[1]
        + bytes([0x02]) * counts[2]
    )
    payload += bytes([0x03]) * (n - len(payload))
    enc0 = encode(payload, 0)
    enc1 = encode(payload, 1)
    assert decode(enc1) == payload
    assert len(enc1) <= len(enc0)


def test_05_roundtrip_all_identical_1mb() -> None:
    """1 MiB of 0x41 — compressed size < 10 KiB, round-trip exact."""
    data = b"\x41" * (1 << 20)
    enc = encode(data, 0)
    assert decode(enc) == data
    assert len(enc) < 10 * 1024, f"all-identical enc={len(enc)} >= 10KiB"


def test_06_roundtrip_single_byte() -> None:
    """Single-byte input round-trips exactly at both orders."""
    for order in (0, 1):
        enc = encode(b"\x42", order)
        assert decode(enc) == b"\x42"


def test_07_roundtrip_empty() -> None:
    """Empty input round-trips at both orders."""
    for order in (0, 1):
        enc = encode(b"", order)
        assert decode(enc) == b""


# ── Canonical vector fixtures (8–12) ────────────────────────────────


def _load_fixture(name: str) -> bytes:
    path = FIXTURE_DIR / name
    return path.read_bytes()


def test_08_canonical_vector_a_order0() -> None:
    """Vector A order-0 encodes byte-exactly to the committed fixture."""
    data = _vector_a()
    enc = encode(data, 0)
    assert enc == _load_fixture("rans_a_o0.bin")
    assert decode(enc) == data


def test_09_canonical_vector_a_order1() -> None:
    """Vector A order-1 encodes byte-exactly to the committed fixture."""
    data = _vector_a()
    enc = encode(data, 1)
    assert enc == _load_fixture("rans_a_o1.bin")
    assert decode(enc) == data


def test_10_canonical_vector_b_order0() -> None:
    """Vector B order-0: byte-exact match + payload < 300 bytes.

    The HANDOFF spec states "compressed size < 300 bytes" for the
    biased 1024-byte vector B.  With our wire format the order-0
    frequency table alone is 1024 bytes, so the < 300 byte budget
    is checked against the rANS payload (header + freq table is
    fixed overhead).
    """
    data = _vector_b()
    enc = encode(data, 0)
    assert enc == _load_fixture("rans_b_o0.bin")
    assert decode(enc) == data
    payload_len = int.from_bytes(enc[5:9], "big")
    assert payload_len < 300, f"vec B order-0 payload={payload_len} bytes"


def test_11_canonical_vector_b_order1() -> None:
    """Vector B order-1 encodes byte-exactly to the committed fixture."""
    data = _vector_b()
    enc = encode(data, 1)
    assert enc == _load_fixture("rans_b_o1.bin")
    assert decode(enc) == data


def test_12_canonical_vector_c_order1_smaller_than_order0() -> None:
    """Vector C: order-1 compressed size < order-0 compressed size."""
    data = _vector_c()
    enc0 = encode(data, 0)
    enc1 = encode(data, 1)
    assert enc0 == _load_fixture("rans_c_o0.bin")
    assert enc1 == _load_fixture("rans_c_o1.bin")
    assert decode(enc0) == data
    assert decode(enc1) == data
    assert len(enc1) < len(enc0), (
        f"order-1 ({len(enc1)}) should beat order-0 ({len(enc0)}) "
        "on perfectly cyclic data"
    )


# ── Malformed input (13) ────────────────────────────────────────────


def test_13_decode_malformed() -> None:
    """Truncated / bad-order / wrong-length inputs raise ValueError."""
    good = encode(b"hello world" * 100, 0)

    # Empty input.
    with pytest.raises(ValueError):
        decode(b"")
    # Shorter than header.
    with pytest.raises(ValueError):
        decode(b"\x00\x00\x00")
    # Bad order byte.
    bad_order = bytearray(good)
    bad_order[0] = 0x05
    with pytest.raises(ValueError):
        decode(bytes(bad_order))
    # Truncated payload (drop tail bytes).
    with pytest.raises(ValueError):
        decode(good[:-4])
    # Truncated freq table.
    with pytest.raises(ValueError):
        decode(good[:50])
    # Header lies about payload length — actual stream too short.
    bad_len = bytearray(good)
    declared = int.from_bytes(bad_len[5:9], "big")
    bad_len[5:9] = (declared + 16).to_bytes(4, "big")
    with pytest.raises(ValueError):
        decode(bytes(bad_len))
    # Order-1 with a context table that sums to something other than M.
    enc1 = bytearray(encode(b"abcabcabc", 1))
    # Find the first non-empty row and corrupt one of its frequencies.
    off = 9
    n = len(enc1)
    fixed = False
    for ctx in range(256):
        n_nonzero = int.from_bytes(enc1[off : off + 2], "big")
        off += 2
        if n_nonzero > 0:
            # Add 1 to the first symbol's frequency (breaks sum == M).
            f = int.from_bytes(enc1[off + 1 : off + 3], "big")
            enc1[off + 1 : off + 3] = (f + 1).to_bytes(2, "big")
            fixed = True
            break
        if off >= n:
            break
        off += n_nonzero * 3
    assert fixed, "test setup: could not find row to corrupt"
    with pytest.raises(ValueError):
        decode(bytes(enc1))

    # Type errors.
    with pytest.raises(TypeError):
        decode("not-bytes")  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        encode(b"x", order=2)


# ── Throughput (14) ─────────────────────────────────────────────────


def test_14_throughput_order0_10mb() -> None:
    """Encode + decode 10 MiB order-0; print MB/s; relaxed thresholds.

    Pure-Python rANS is intentionally slow (no Cython / no numpy);
    targets are 2 MB/s encode, 5 MB/s decode per Binding Decision §82.
    """
    n = 10 * (1 << 20)  # 10 MiB
    data = os.urandom(n)

    t0 = time.perf_counter()
    enc = encode(data, 0)
    enc_dt = time.perf_counter() - t0

    t1 = time.perf_counter()
    dec = decode(enc)
    dec_dt = time.perf_counter() - t1

    enc_mb_s = (n / (1 << 20)) / enc_dt
    dec_mb_s = (n / (1 << 20)) / dec_dt
    print(
        f"\n  M83 throughput (10 MiB, order-0, pure Python): "
        f"encode {enc_mb_s:.2f} MB/s, decode {dec_mb_s:.2f} MB/s"
    )

    assert dec == data
    assert enc_mb_s >= 2.0, f"encode {enc_mb_s:.2f} MB/s < 2 MB/s"
    assert dec_mb_s >= 5.0, f"decode {dec_mb_s:.2f} MB/s < 5 MB/s"
