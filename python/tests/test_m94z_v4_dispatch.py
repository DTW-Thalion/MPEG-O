"""V4 dispatch tests for fqzcomp_nx16_z.encode / decode_with_metadata.

V4 wire format (version byte = 4) carries a CRAM 3.1 fqzcomp_qual body
produced by libttio_rans's :c:func:`ttio_m94z_v4_encode`. Per the L2.X
Stage 2 plan, V4 is the new default codec when the native library is
available (supersedes V3 from L2 / Task #82 Phase B.2).

The native library is required for V4 — there is no pure-Python or
Cython fallback. Tests skip cleanly when libttio_rans is not loaded.
"""
from __future__ import annotations

import os

import pytest

from ttio.codecs.fqzcomp_nx16_z import (
    _HAVE_NATIVE_LIB,
    decode_with_metadata,
    encode,
)

# 3 reads x 4 qualities, mixed Q-values, mixed revcomp.
SYNTH_QUALITIES = bytes([
    ord('I'), ord('I'), ord('?'), ord('?'),
    ord('5'), ord('5'), ord('5'), ord('5'),
    ord('I'), ord('?'), ord('I'), ord('?'),
])
SYNTH_READ_LENS = [4, 4, 4]
# revcomp_flags is 0/1 in the Python API (the encoder translates 1 -> SAM_REVERSE
# bit 4 internally); see _encode_v4_native in fqzcomp_nx16_z.py.
SYNTH_REVCOMP = [0, 1, 0]


pytestmark = pytest.mark.skipif(
    not _HAVE_NATIVE_LIB,
    reason="V4 needs libttio_rans (set TTIO_RANS_LIB_PATH)",
)


def test_v4_smoke_roundtrip():
    """V4 encode emits magic+version=4; decode recovers qualities."""
    out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP, prefer_v4=True)
    assert out[:4] == b"M94Z"
    assert out[4] == 4
    qual, lens, _rev = decode_with_metadata(out, SYNTH_REVCOMP)
    assert qual == SYNTH_QUALITIES
    assert list(lens) == SYNTH_READ_LENS


def test_v4_default_when_native():
    """Without prefer_v4, V4 is chosen when native lib is loaded."""
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    old_use = os.environ.get("TTIO_M94Z_USE_NATIVE")
    try:
        os.environ.pop("TTIO_M94Z_VERSION", None)
        os.environ.pop("TTIO_M94Z_USE_NATIVE", None)
        out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP)
    finally:
        if old_ver is not None:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
        if old_use is not None:
            os.environ["TTIO_M94Z_USE_NATIVE"] = old_use
    assert out[4] == 4


def test_v3_explicit_still_works():
    """``prefer_v3=True`` (with ``prefer_v4=False``) selects V3."""
    out = encode(
        SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP,
        prefer_v4=False, prefer_v3=True,
    )
    assert out[4] == 3
    qual, _, _ = decode_with_metadata(out, SYNTH_REVCOMP)
    assert qual == SYNTH_QUALITIES


def test_env_var_v4_selects_v4():
    """``TTIO_M94Z_VERSION=4`` forces V4."""
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    try:
        os.environ["TTIO_M94Z_VERSION"] = "4"
        out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP)
    finally:
        if old_ver is None:
            os.environ.pop("TTIO_M94Z_VERSION", None)
        else:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
    assert out[4] == 4


def test_env_var_v3_selects_v3():
    """``TTIO_M94Z_VERSION=3`` overrides the V4 default."""
    old_ver = os.environ.get("TTIO_M94Z_VERSION")
    try:
        os.environ["TTIO_M94Z_VERSION"] = "3"
        out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP)
    finally:
        if old_ver is None:
            os.environ.pop("TTIO_M94Z_VERSION", None)
        else:
            os.environ["TTIO_M94Z_VERSION"] = old_ver
    assert out[4] == 3


def test_v4_size_sanity_vs_v3():
    """Loose sanity: V4 is in the same ballpark as V3 on Illumina-like input.

    This is a sanity check, not a strict requirement — V4 may compress
    slightly worse on some pathological inputs. Tolerance: 100 bytes.
    """
    rng = __import__("random").Random(0xBEEF)
    n_reads = 200
    read_len = 101
    quals = bytearray()
    for _ in range(n_reads * read_len):
        q = max(20, min(40, int(rng.gauss(30, 5))))
        quals.append(q + 33)
    qualities = bytes(quals)
    read_lens = [read_len] * n_reads
    revcomp = [0] * n_reads
    v3 = encode(qualities, read_lens, revcomp, prefer_v4=False, prefer_v3=True)
    v4 = encode(qualities, read_lens, revcomp, prefer_v4=True)
    assert v3[4] == 3
    assert v4[4] == 4
    assert len(v4) <= len(v3) + 100, (
        f"V4 unexpectedly larger than V3 by >100 bytes: V4={len(v4)} V3={len(v3)}"
    )


def test_v4_v3_cross_decode_fails():
    """A V4-encoded stream tampered to version=3 must fail to decode.

    The V3 decoder expects a V3 outer-header layout entirely different
    from V4's. The decode path tries to zlib-decompress a read-length
    table that doesn't exist at that offset, so the raised exception
    can be ValueError, RuntimeError, or zlib.error — any non-success
    path is acceptable here (we only assert that V4 bytes don't accidentally
    decode as V3).
    """
    v4 = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP, prefer_v4=True)
    assert v4[4] == 4
    tampered = v4[:4] + bytes([3]) + v4[5:]
    with pytest.raises(Exception):
        decode_with_metadata(tampered, SYNTH_REVCOMP)


def test_v4_pad_count_correct():
    """13 qualities -> pad_count = 3; output should round-trip exactly."""
    qual_13 = SYNTH_QUALITIES + bytes([ord('@')])  # 13 bytes
    lens_13 = SYNTH_READ_LENS + [1]
    rev_13 = SYNTH_REVCOMP + [0]
    out = encode(qual_13, lens_13, rev_13, prefer_v4=True)
    assert out[4] == 4
    qual, lens, _ = decode_with_metadata(out, rev_13)
    assert qual == qual_13
    assert list(lens) == lens_13


def test_v4_empty_input_rejected():
    """Empty input is not supported by the V4 native encoder.

    The CRAM 3.1 fqzcomp_qual encoder rejects ``n_qualities == 0 ||
    n_reads == 0`` (see native/src/fqzcomp_qual.c:1394). Empty inputs
    should fall back to V3/V2/V1 via ``prefer_v4=False``.
    """
    with pytest.raises(RuntimeError, match="ttio_m94z_v4_encode failed"):
        encode(b"", [], [], prefer_v4=True)
    # Empty input via the V3 fallback works:
    out = encode(b"", [], [], prefer_v4=False, prefer_v3=True)
    assert out[4] == 3
    qual, lens, _ = decode_with_metadata(out, [])
    assert qual == b""
    assert list(lens) == []


def test_v4_single_read():
    """Single-read input round-trips."""
    qual = bytes([ord('I')] * 50)
    out = encode(qual, [50], [0], prefer_v4=True)
    assert out[4] == 4
    qual_back, lens, _ = decode_with_metadata(out, [0])
    assert qual_back == qual
    assert list(lens) == [50]


def test_v4_mixed_revcomp_roundtrip():
    """Multi-read input with mixed revcomp flags round-trips exactly."""
    rls = [50, 80, 60, 70, 40]
    rcs = [0, 1, 0, 1, 0]
    qualities = bytes((33 + 30 + ((i * 17) % 31)) for i in range(sum(rls)))
    out = encode(qualities, rls, rcs, prefer_v4=True)
    assert out[4] == 4
    qual_back, lens, _ = decode_with_metadata(out, rcs)
    assert qual_back == qualities
    assert list(lens) == rls
