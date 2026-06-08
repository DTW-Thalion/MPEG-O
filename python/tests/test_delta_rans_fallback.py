"""Coverage + equivalence for the pure-Python DELTA_RANS fallback path.

The Cython accelerator in :mod:`ttio.codecs._delta_rans` short-circuits the
serial LEB128 varint emit/parse loops in :mod:`ttio.codecs.delta_rans` away
from the pure-Python reference, so those branches stay uncovered in the
default coverage run (the extension is built in CI). These tests force
``_HAVE_C_EXTENSION = False`` so the pure-Python varint loops, the
``_decode_int64_scalar`` overflow fallback, and the scalar ``_varint_encode``
are exercised end-to-end — and assert their output is byte-identical to the
Cython fast path.

Complements ``test_m95_delta_rans.py`` / ``test_delta_rans_vectorization.py``
(which cover the public API through the Cython fast path).
"""
from __future__ import annotations

import struct

import numpy as np
import pytest

from ttio.codecs import delta_rans as dr

_FMT = {1: "b", 4: "i", 8: "q"}


def _pack(vals, es):
    return struct.pack(f"<{len(vals)}{_FMT[es]}", *vals)


def _force_python(fn, *args):
    saved = dr._HAVE_C_EXTENSION
    dr._HAVE_C_EXTENSION = False
    try:
        return fn(*args)
    finally:
        dr._HAVE_C_EXTENSION = saved


# In-range int64 bands so consecutive deltas do not overflow int64 (the codec
# cannot round-trip overflowing int64 deltas — see test_delta_rans_vectorization).
_CASES = [
    (1, []),
    (1, [0]),
    (1, list(range(-128, 128))),
    (4, [0]),
    (4, [0, 1, 2, 3, 100, -100, 2**30, -(2**30)]),
    (4, list(range(0, 2000))),
    (8, []),
    (8, [0]),
    (8, [1000 + i * 150 for i in range(200)]),
    (8, [-(1 << 40), 0, 1 << 40, (1 << 40) + 7]),
]


@pytest.mark.parametrize("es,vals", _CASES)
def test_pure_python_matches_c_extension(es, vals):
    data = _pack(vals, es)
    c_enc = dr.encode(data, es)
    p_enc = _force_python(dr.encode, data, es)
    assert c_enc == p_enc, f"encode byte-diff es={es}"
    # round-trip through both decode paths
    assert dr.decode(c_enc) == data
    assert _force_python(dr.decode, c_enc) == data
    # decode outputs identical
    assert dr.decode(c_enc) == _force_python(dr.decode, c_enc)


def test_pure_python_varint_primitives():
    values = [0, 1, 127, 128, 16383, 16384, 300, 500, 2**20, 2**63 - 1]
    buf = bytearray()
    for v in values:
        buf.extend(dr._varint_encode(v))
    assert dr._varint_decode_all(bytes(buf)) == values


def test_pure_python_truncated_varint_raises():
    with pytest.raises(ValueError, match="truncated varint"):
        dr._varint_decode_all(bytes([0x80]))  # continuation bit, no terminator


def test_int64_overflow_raises_struct_error_both_paths():
    """Overflowing int64 deltas must raise struct.error on decode for both the
    vectorized fast path and the scalar fallback (pre-existing codec limit)."""
    data = _pack([2**63 - 1, -(2**63)], 8)
    enc = dr.encode(data, 8)
    with pytest.raises(struct.error):
        dr.decode(enc)  # vectorized path detects overflow -> scalar -> raises
    with pytest.raises(struct.error):
        _force_python(dr.decode, enc)
