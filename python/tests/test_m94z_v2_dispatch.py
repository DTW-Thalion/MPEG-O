"""Round-trip tests for M94.Z V2 native dispatch (Task 21).

V2 wire format (version byte = 2) carries a self-contained native body
produced by libttio_rans's :c:func:`ttio_rans_encode_block`. V1 streams
remain the default unless ``prefer_native=True`` (or env var
``TTIO_M94Z_USE_NATIVE`` is set) is passed to :func:`encode`.

NOTE: as of L2 (Task #82 Phase B.2, 2026-05-01) V3 (adaptive Range Coder)
is the default when libttio_rans is available. The V1/V2 round-trip
tests below explicitly request the legacy code paths via
``prefer_v3=False`` (and either ``prefer_native=True`` for V2 or
``prefer_native=False`` for V1).

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


def _v1(*args, **kwargs) -> bytes:
    """Encode forcing V1 (legacy Cython / pure-Python path)."""
    kwargs.setdefault("prefer_v3", False)
    kwargs.setdefault("prefer_native", False)
    return encode(*args, **kwargs)


def _v2(*args, **kwargs) -> bytes:
    """Encode forcing V2 (native body, legacy)."""
    kwargs["prefer_v3"] = False
    kwargs["prefer_native"] = True
    return encode(*args, **kwargs)


def _make_data(n_reads: int = 100, read_len: int = 80) -> tuple[bytes, list[int], list[int]]:
    """Synthetic FASTQ-like quality stream for round-trip testing."""
    qualities = bytes((33 + 20 + ((i * 31) % 21)) for i in range(n_reads * read_len))
    read_lengths = [read_len] * n_reads
    revcomp_flags = [(i & 1) for i in range(n_reads)]
    return qualities, read_lengths, revcomp_flags


def _native_available() -> bool:
    return "native" in get_backend_name()


# ── V1 default path ────────────────────────────────────────────────────


def test_v1_explicit_emits_version_byte_1():
    """``prefer_v3=False, prefer_native=False`` must produce V1."""
    qualities, rls, rcs = _make_data(n_reads=20, read_len=64)
    encoded = _v1(qualities, rls, rcs)
    assert encoded[:4] == b"M94Z"
    assert encoded[4] == 1, (
        f"explicit V1 encode must produce V1, got version={encoded[4]}"
    )


def test_v1_roundtrip_explicit():
    """V1 (explicit) round-trips qualities exactly."""
    qualities, rls, rcs = _make_data(n_reads=30, read_len=72)
    encoded = _v1(qualities, rls, rcs)
    decoded, dec_rls, dec_rcs = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities
    assert dec_rls == rls
    assert dec_rcs == rcs


# ── V2 native dispatch ────────────────────────────────────────────────


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_encode_emits_version_byte_2():
    """encode(prefer_native=True) must produce V2 (version=2)."""
    qualities, rls, rcs = _make_data(n_reads=40, read_len=64)
    encoded = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    assert encoded[:4] == b"M94Z"
    assert encoded[4] == VERSION_V2_NATIVE
    assert encoded[4] == 2


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_roundtrip_native_encode():
    """V2 encode (native) + V2 decode (pure-python) round-trips qualities."""
    qualities, rls, rcs = _make_data()
    encoded = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
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
    encoded = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_roundtrip_unaligned():
    """V2 round-trip with non-multiple-of-4 length (exercises padding)."""
    qualities = bytes(range(33, 33 + 17))  # 17 bytes
    rls = [17]
    rcs = [0]
    encoded = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_roundtrip_multi_read():
    """V2 round-trip with multiple variable-length reads."""
    rls = [50, 80, 60, 70, 40]
    rcs = [0, 1, 0, 1, 0]
    qualities = bytes((33 + 30 + ((i * 17) % 31)) for i in range(sum(rls)))
    encoded = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    decoded, dec_rls, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities
    assert dec_rls == rls


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_env_var_enables_native():
    """TTIO_M94Z_VERSION=2 must opt into V2 encode."""
    qualities, rls, rcs = _make_data(n_reads=10, read_len=32)
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    old_use = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ["TTIO_M94Z_VERSION"] = "2"
        os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        encoded = encode(qualities, rls, rcs)
        assert encoded[4] == 2, "TTIO_M94Z_VERSION=2 should enable V2"
    finally:
        if old_ver is None:
            os.environ.pop("TTIO_M94Z_VERSION", None)
        else:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
        if old_use is not None:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old_use

    # Round-trip via the env-var-enabled stream.
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=rcs)
    assert decoded == qualities


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_env_var_off_does_not_enable_native():
    """Without TTIO_M94Z_VERSION/USE_NATIVE → V3 default (native available)."""
    qualities, rls, rcs = _make_data(n_reads=10, read_len=32)
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    old_use = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ.pop("TTIO_M94Z_VERSION", None)
        os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        encoded = encode(qualities, rls, rcs)
        assert encoded[4] == 3, (
            "without env vars, default must be V3 (native available)"
        )
    finally:
        if old_ver is not None:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
        if old_use is not None:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old_use


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v2_explicit_false_overrides_env():
    """prefer_native=False (with prefer_v3=False) forces V1 regardless of env."""
    qualities, rls, rcs = _make_data(n_reads=8, read_len=32)
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    old_use = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ["TTIO_M94Z_VERSION"] = "2"
        os.environ["TTIO_M94Z_USE_NATIVE"] = "1"
        encoded = encode(
            qualities, rls, rcs,
            prefer_v3=False, prefer_native=False,
        )
        assert encoded[4] == 1, "explicit V1 must override env vars"
    finally:
        if old_ver is None:
            os.environ.pop("TTIO_M94Z_VERSION", None)
        else:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
        if old_use is None:
            os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        else:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old_use


# ── V1 / V2 byte-format independence ───────────────────────────────────


def test_v1_decode_compatibility():
    """Explicit-V1 decode unchanged (post-L2 default is V3 — opt out)."""
    qualities, rls, rcs = _make_data(n_reads=25, read_len=48)
    encoded_v1 = _v1(qualities, rls, rcs)
    assert encoded_v1[4] == 1
    decoded_v1, _, _ = decode_with_metadata(encoded_v1, revcomp_flags=rcs)
    assert decoded_v1 == qualities


@pytest.mark.skipif(not _native_available(), reason="native libttio_rans not available")
def test_v1_v2_produce_same_qualities():
    """V1 and V2 must decode to the same payload (compressed bytes differ)."""
    qualities, rls, rcs = _make_data(n_reads=15, read_len=64)
    enc_v1 = _v1(qualities, rls, rcs)
    enc_v2 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
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
    encoded_v2 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    decoded, _, _ = decode_with_metadata(encoded_v2, revcomp_flags=rcs)
    assert decoded == qualities


# Task 26b: V2 native streaming decode

def _helper_decode_v2_streaming(enc_v2, rcs):
    from ttio.codecs.fqzcomp_nx16_z import (
        _decode_v2_via_native_streaming,
        _unpack_codec_header_v2,
        _deserialize_freq_tables,
        _decode_read_lengths,
    )
    header, body_off = _unpack_codec_header_v2(enc_v2)
    body = enc_v2[body_off:]
    n_qualities = header.num_qualities
    pad_count = (header.flags >> 4) & 0x3
    n_padded = n_qualities + pad_count
    freq_per_ctx = _deserialize_freq_tables(header.freq_tables_compressed)
    ctx_params = header.context_params
    read_lengths = _decode_read_lengths(header.read_length_table, header.num_reads)
    return _decode_v2_via_native_streaming(
        bytes(body), n_qualities, n_padded, freq_per_ctx,
        ctx_params.qbits, ctx_params.pbits, ctx_params.sloc,
        read_lengths, rcs,
    )

@pytest.mark.skipif(not _native_available(), reason='native libttio_rans not available')
def test_v2_streaming_matches_pure_python():
    import ttio.codecs.fqzcomp_nx16_z as _mod
    qualities, rls, rcs = _make_data()
    enc_v2 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    # Pure-Python decode
    orig_flag = _mod._HAVE_NATIVE_LIB
    _mod._HAVE_NATIVE_LIB = False
    try:
        dec_pure, _, _ = _mod._decode_v2_with_metadata(enc_v2, rcs)
    finally:
        _mod._HAVE_NATIVE_LIB = orig_flag
    # Native streaming decode
    dec_native = _helper_decode_v2_streaming(enc_v2, rcs)
    assert dec_native == qualities
    assert dec_native == dec_pure


@pytest.mark.skipif(not _native_available(), reason='native libttio_rans not available')
def test_v2_streaming_roundtrip_small():
    qualities = b'!' * 16
    rls = [16]
    rcs = [0]
    enc_v2 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    dec = _helper_decode_v2_streaming(enc_v2, rcs)
    assert dec == qualities


@pytest.mark.skipif(not _native_available(), reason='native libttio_rans not available')
def test_v2_streaming_roundtrip_unaligned():
    qualities = bytes(range(33, 33 + 17))
    rls = [17]
    rcs = [0]
    enc_v2 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    dec = _helper_decode_v2_streaming(enc_v2, rcs)
    assert dec == qualities


@pytest.mark.skipif(not _native_available(), reason='native libttio_rans not available')
def test_v2_streaming_roundtrip_multi_read():
    rls = [50, 80, 60, 70, 40]
    rcs = [0, 1, 0, 1, 0]
    qualities = bytes((33 + 30 + ((i * 17) % 31)) for i in range(sum(rls)))
    enc_v2 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    dec = _helper_decode_v2_streaming(enc_v2, rcs)
    assert dec == qualities


@pytest.mark.skipif(not _native_available(), reason='native libttio_rans not available')
def test_v2_decode_uses_native_streaming_larger_block():
    qualities, rls, rcs = _make_data(n_reads=200, read_len=100)
    enc_v2 = encode(qualities, rls, rcs, prefer_v3=False, prefer_native=True)
    assert enc_v2[4] == 2
    dec, _, _ = decode_with_metadata(enc_v2, revcomp_flags=rcs)
    assert dec == qualities


def test_v2_streaming_raises_when_no_native():
    import ttio.codecs.fqzcomp_nx16_z as _mod
    from ttio.codecs.fqzcomp_nx16_z import _decode_v2_via_native_streaming
    orig_flag = _mod._HAVE_NATIVE_LIB
    _mod._HAVE_NATIVE_LIB = False
    try:
        with pytest.raises(RuntimeError, match='libttio_rans not available'):
            _decode_v2_via_native_streaming(
                b'dummy', 0, 0, {0: [1] + [0] * 255}, 12, 2, 14, [0], [0],
            )
    finally:
        _mod._HAVE_NATIVE_LIB = orig_flag
