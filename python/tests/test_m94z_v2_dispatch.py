"""Round-trip tests for M94.Z V2 native dispatch (Task 21).

V2 wire format (version byte = 2) carries a self-contained native body
produced by libttio_rans's :c:func:`ttio_rans_encode_block`. V1 streams
remain the default unless ``prefer_native=True`` (or env var
``TTIO_M94Z_USE_NATIVE`` is set) is passed to :func:`encode`.

V2 decode is pure-Python in this revision (Task 21 scope) — see
``_decode_v2_with_metadata`` in fqzcomp_nx16_z.py for design notes on
why the C library cannot drive V2 decode without a streaming context
API.
"""
from __future__ import annotations

import os

import pytest

from ttio.codecs.fqzcomp_nx16_z import (
    VERSION_V2_NATIVE,
    decode_with_metadata,
    encode,
    get_backend_name,
)


def _make_data(n_reads: int = 100, read_len: int = 80) -> tuple[bytes, list[int], list[int]]:
    """Synthetic FASTQ-like quality stream for round-trip testing."""
    qualities = bytes((33 + 20 + ((i * 31) % 21)) for i in range(n_reads * read_len))
    read_lengths = [read_len] * n_reads
    revcomp_flags = [(i & 1) for i in range(n_reads)]
    return qualities, read_lengths, revcomp_flags


def _native_available() -> bool:
    return "native" in get_backend_name()


# ── V1 default path ────────────────────────────────────────────────────


def test_default_encode_emits_v1():
    """Default encoder (no prefer_native) must produce V1 (version=1)."""
    qualities, rls, rcs = _make_data(n_reads=20, read_len=64)
    encoded = encode(qualities, rls, rcs)
    assert encoded[:4] == b"M94Z"
    assert encoded[4] == 1, f"default encode must produce V1, got version={encoded[4]}"


def test_v1_roundtrip_default():
    """V1 (default) round-trips qualities exactly."""
    qualities, rls, rcs = _make_data(n_reads=30, read_len=72)
    encoded = encode(qualities, rls, rcs)
    decoded, dec_rls, dec_rcs = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities
    assert dec_rls == rls
    assert dec_rcs == rcs


# ── V2 native dispatch ────────────────────────────────────────────────


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_encode_emits_version_byte_2():
    """encode(prefer_native=True) must produce V2 (version=2)."""
    qualities, rls, rcs = _make_data(n_reads=40, read_len=64)
    encoded = encode(qualities, rls, rcs, prefer_native=True)
    assert encoded[:4] == b"M94Z"
    assert encoded[4] == VERSION_V2_NATIVE
    assert encoded[4] == 2


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_roundtrip_native_encode():
    """V2 encode (native) + V2 decode (pure-python) round-trips qualities."""
    qualities, rls, rcs = _make_data()
    encoded = encode(qualities, rls, rcs, prefer_native=True)
    assert encoded[4] == 2

    decoded, dec_rls, dec_rcs = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities, (
        f"V2 round-trip mismatch: decoded {len(decoded)} bytes, "
        f"original {len(qualities)} bytes; first diff at "
        f"{next((i for i, (a, b) in enumerate(zip(decoded, qualities)) if a != b), -1)}"
    )
    assert dec_rls == rls
    assert dec_rcs == rcs


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_roundtrip_small():
    """V2 round-trip on a small input (4-byte aligned)."""
    qualities = b"!" * 16  # 16 bytes, all same symbol
    rls = [16]
    rcs = [0]
    encoded = encode(qualities, rls, rcs, prefer_native=True)
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_roundtrip_unaligned():
    """V2 round-trip with non-multiple-of-4 length (exercises padding)."""
    qualities = bytes(range(33, 33 + 17))  # 17 bytes
    rls = [17]
    rcs = [0]
    encoded = encode(qualities, rls, rcs, prefer_native=True)
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_roundtrip_multi_read():
    """V2 round-trip with multiple variable-length reads."""
    rls = [50, 80, 60, 70, 40]
    rcs = [0, 1, 0, 1, 0]
    qualities = bytes((33 + 30 + ((i * 17) % 31)) for i in range(sum(rls)))
    encoded = encode(qualities, rls, rcs, prefer_native=True)
    decoded, dec_rls, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities
    assert dec_rls == rls


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_env_var_enables_native():
    """TTIO_M94Z_USE_NATIVE=1 must opt into V2 encode."""
    qualities, rls, rcs = _make_data(n_reads=10, read_len=32)
    old = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ["TTIO_M94Z_USE_NATIVE"] = "1"
        encoded = encode(qualities, rls, rcs)
        assert encoded[4] == 2, "env var should enable V2 path"
    finally:
        if old is None:
            os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        else:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old

    # Round-trip via the env-var-enabled stream.
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_env_var_off_does_not_enable_native():
    """TTIO_M94Z_USE_NATIVE unset → V1 default."""
    qualities, rls, rcs = _make_data(n_reads=10, read_len=32)
    old = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        encoded = encode(qualities, rls, rcs)
        assert encoded[4] == 1, "without env var, must default to V1"
    finally:
        if old is not None:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_explicit_false_overrides_env():
    """prefer_native=False overrides env var."""
    qualities, rls, rcs = _make_data(n_reads=8, read_len=32)
    old = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ["TTIO_M94Z_USE_NATIVE"] = "1"
        encoded = encode(qualities, rls, rcs, prefer_native=False)
        assert encoded[4] == 1, "prefer_native=False must force V1"
    finally:
        if old is None:
            os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        else:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old


# ── V1 / V2 byte-format independence ───────────────────────────────────


def test_v1_v2_decode_compatibility():
    """V1 (default) decode unchanged."""
    qualities, rls, rcs = _make_data(n_reads=25, read_len=48)
    encoded_v1 = encode(qualities, rls, rcs)  # default: V1
    assert encoded_v1[4] == 1
    decoded_v1, _, _ = decode_with_metadata(encoded_v1, revcomp_flags=rcs)
    assert decoded_v1 == qualities


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v1_v2_produce_same_qualities():
    """V1 and V2 must decode to the same payload (compressed bytes differ)."""
    qualities, rls, rcs = _make_data(n_reads=15, read_len=64)
    enc_v1 = encode(qualities, rls, rcs)
    enc_v2 = encode(qualities, rls, rcs, prefer_native=True)
    assert enc_v1[4] == 1
    assert enc_v2[4] == 2
    # Compressed bytes WILL differ — different wire format.
    dec_v1, _, _ = decode_with_metadata(enc_v1, revcomp_flags=rcs)
    dec_v2, _, _ = decode_with_metadata(enc_v2, revcomp_flags=rcs)
    assert dec_v1 == qualities
    assert dec_v2 == qualities
    assert dec_v1 == dec_v2


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_decode_when_native_only_for_encode():
    """V2 streams round-trip whether or not native is the encode default."""
    qualities, rls, rcs = _make_data(n_reads=50, read_len=64)
    encoded_v2 = encode(qualities, rls, rcs, prefer_native=True)
    decoded, _, _ = decode_with_metadata(encoded_v2, revcomp_flags=rcs)
    assert decoded == qualities
