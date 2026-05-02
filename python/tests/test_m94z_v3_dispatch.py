"""Round-trip tests for M94.Z V3 adaptive Range Coder (L2, Task #82).

V3 wire format (version byte = 3) carries an adaptive RC body produced
by libttio_rans's :c:func:`ttio_rans_encode_block_adaptive`. Per spec
``2026-05-01-l2-m94z-adaptive-design.md`` §5, V3 replaces V1 and V2 as
the default codec when the native library is available.

The native library is required for V3 — there is no pure-Python or
Cython fallback (per spec §7).
"""
from __future__ import annotations

import os

import pytest

from ttio.codecs.fqzcomp_nx16_z import (
    VERSION_V3_ADAPTIVE,
    decode_with_metadata,
    encode,
    get_backend_name,
)


def _make_data(
    n_reads: int = 10,
    read_len: int = 50,
) -> tuple[bytes, list[int], list[int]]:
    qualities = bytes((33 + 20 + ((i * 7) % 21)) for i in range(n_reads * read_len))
    return qualities, [read_len] * n_reads, [0] * n_reads


def _native_available() -> bool:
    return "native" in get_backend_name()


pytestmark = pytest.mark.skipif(
    not _native_available(),
    reason="native libttio_rans not available — V3 requires native",
)


def test_v3_default_when_native_available():
    """With native lib loaded and no env override, encode defaults to V3."""
    qualities, rls, rcs = _make_data()
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    old_use = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ.pop("TTIO_M94Z_VERSION", None)
        os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        encoded = encode(qualities, rls, rcs)
    finally:
        if old_ver is not None:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
        if old_use is not None:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old_use
    assert encoded[:4] == b"M94Z"
    assert encoded[4] == VERSION_V3_ADAPTIVE


def test_v3_explicit_emits_version_byte_3():
    """``prefer_v3=True`` always selects V3 (when native available)."""
    qualities, rls, rcs = _make_data(n_reads=20, read_len=64)
    encoded = encode(qualities, rls, rcs, prefer_v3=True)
    assert encoded[:4] == b"M94Z"
    assert encoded[4] == 3


def test_v3_roundtrip_small():
    """Smoke test: 10 reads × 50 bp synthetic Q20–Q40 round-trips."""
    qualities = bytes((20 + (i * 7) % 21) for i in range(500))
    read_lengths = [50] * 10
    revcomp = [0] * 10
    enc = encode(qualities, read_lengths, revcomp, prefer_v3=True)
    assert enc[4] == 3
    out, dec_rls, dec_rcs = decode_with_metadata(enc)
    assert out == qualities
    assert dec_rls == read_lengths
    assert dec_rcs == revcomp


def test_v3_roundtrip_aligned():
    """V3 round-trip on a 4-byte-aligned input."""
    qualities = b"!" * 16
    rls = [16]
    rcs = [0]
    encoded = encode(qualities, rls, rcs, prefer_v3=True)
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities


def test_v3_roundtrip_unaligned():
    """V3 round-trip with non-multiple-of-4 length (exercises padding)."""
    qualities = bytes(range(33, 33 + 17))  # 17 bytes
    rls = [17]
    rcs = [0]
    encoded = encode(qualities, rls, rcs, prefer_v3=True)
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities


def test_v3_roundtrip_multi_read_mixed_revcomp():
    """V3 round-trip with multiple reads and mixed revcomp flags."""
    rls = [50, 80, 60, 70, 40]
    rcs = [0, 1, 0, 1, 0]
    qualities = bytes((33 + 30 + ((i * 17) % 31)) for i in range(sum(rls)))
    encoded = encode(qualities, rls, rcs, prefer_v3=True)
    decoded, dec_rls, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities
    assert dec_rls == rls


def test_v3_roundtrip_large():
    """V3 round-trip on 100 reads × 100bp."""
    rls = [100] * 100
    rcs = [(i & 1) for i in range(100)]
    qualities = bytes((33 + 20 + ((i * 31) % 21)) for i in range(sum(rls)))
    encoded = encode(qualities, rls, rcs, prefer_v3=True)
    assert encoded[4] == 3
    decoded, dec_rls, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities
    assert dec_rls == rls


def test_v3_compresses_better_than_v1_on_redundant_data():
    """On low-entropy input V3 should match or beat V1 compression."""
    qualities = b"!" * 5000  # all same symbol
    rls = [5000]
    rcs = [0]
    enc_v1 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=False)
    enc_v3 = encode(qualities, rls, rcs, prefer_v3=True)
    # V1 carries a sidecar freq-table blob; V3 doesn't. On highly
    # redundant input V3's adaptive model should produce a smaller body.
    assert enc_v3[4] == 3
    assert enc_v1[4] == 1
    decoded, _, _ = decode_with_metadata(enc_v3)
    assert decoded == qualities
    # Sanity: V3 must at least match V1 within a small slack (the
    # adaptive update cost on 5K Q35 should make V3 smaller).
    assert len(enc_v3) <= len(enc_v1) + 64


def test_v3_env_var_selects_version():
    """``TTIO_M94Z_VERSION=3`` selects V3 regardless of other env vars."""
    qualities, rls, rcs = _make_data()
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    try:
        os.environ["TTIO_M94Z_VERSION"] = "3"
        encoded = encode(qualities, rls, rcs)
    finally:
        if old_ver is None:
            os.environ.pop("TTIO_M94Z_VERSION", None)
        else:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
    assert encoded[4] == 3


def test_v3_env_var_can_select_v1():
    """``TTIO_M94Z_VERSION=1`` overrides the V3 default."""
    qualities, rls, rcs = _make_data()
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    old_use = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ["TTIO_M94Z_VERSION"] = "1"
        os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        encoded = encode(qualities, rls, rcs)
    finally:
        if old_ver is None:
            os.environ.pop("TTIO_M94Z_VERSION", None)
        else:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
        if old_use is not None:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old_use
    assert encoded[4] == 1


def test_v3_decode_dispatches_on_version_byte():
    """`decode_with_metadata` routes V3 streams to the V3 decoder."""
    qualities, rls, rcs = _make_data()
    enc_v3 = encode(qualities, rls, rcs, prefer_v3=True)
    enc_v1 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=False)
    assert enc_v3[4] == 3 and enc_v1[4] == 1
    dec_v3, _, _ = decode_with_metadata(enc_v3, revcomp_flags=rcs)
    dec_v1, _, _ = decode_with_metadata(enc_v1, revcomp_flags=rcs)
    assert dec_v3 == qualities
    assert dec_v1 == qualities
    assert dec_v3 == dec_v1
