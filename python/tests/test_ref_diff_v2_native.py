"""Round-trip tests for the Python ctypes wrapper of ref_diff_v2."""
from __future__ import annotations

import hashlib

import numpy as np
import pytest

from ttio.codecs import ref_diff_v2 as rdv2

if not rdv2.HAVE_NATIVE_LIB:
    pytest.skip("requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
                allow_module_level=True)


def _make_synthetic_corpus(n: int, seed: int = 42):
    """Build n synthetic 100bp reads with 1% sub rate against ACGT-cycle reference."""
    rng = np.random.default_rng(seed)
    ref_bytes = bytearray(ord("ACGT"[i % 4]) for i in range(n * 100 + 200))
    reference = bytes(ref_bytes)
    sequences = bytearray()
    offsets = [0]
    positions = []
    cigars = []
    for r in range(n):
        ref_pos = r * 50  # overlapping
        read = bytearray(reference[ref_pos:ref_pos + 100])
        # ~1% sub rate
        for i in range(100):
            if int(rng.integers(0, 100)) == 0:
                idx = b"ACGT".index(read[i])
                read[i] = b"ACGT"[(idx + 1) % 4]
        sequences.extend(read)
        offsets.append(len(sequences))
        positions.append(ref_pos + 1)  # 1-based
        cigars.append("100M")
    return (
        np.frombuffer(bytes(sequences), dtype=np.uint8).copy(),
        np.asarray(offsets, dtype=np.uint64),
        np.asarray(positions, dtype=np.int64),
        cigars,
        reference,
    )


@pytest.mark.parametrize("n", [1, 100, 1000])
def test_round_trip(n):
    seq, off, pos, cigars, ref = _make_synthetic_corpus(n)
    md5 = hashlib.md5(ref).digest()
    encoded = rdv2.encode(seq, off, pos, cigars, ref, md5, "test")
    assert encoded[:4] == b"RDF2"
    assert len(encoded) > 38  # at least header

    out_seq, out_off = rdv2.decode(encoded, pos, cigars, ref, n, int(off[n]))
    np.testing.assert_array_equal(seq, out_seq)
    np.testing.assert_array_equal(off, out_off)
