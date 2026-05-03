"""Round-trip tests for the Python ctypes wrapper of mate_info_v2.

Requires TTIO_RANS_LIB_PATH set to a built libttio_rans.so.
"""
from __future__ import annotations

import numpy as np
import pytest

from ttio.codecs import mate_info_v2 as miv2

if not miv2.HAVE_NATIVE_LIB:
    pytest.skip("requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
                allow_module_level=True)


def _make_record_set(n, seed=42):
    rng = np.random.default_rng(seed)
    own_chrom_ids = rng.integers(0, 24, size=n, dtype=np.uint16)
    own_positions = rng.integers(0, 100_000_000, size=n, dtype=np.int64)
    mate_chrom_ids = np.empty(n, dtype=np.int32)
    mate_positions = np.empty(n, dtype=np.int64)
    template_lengths = rng.integers(-500, 500, size=n, dtype=np.int32)
    for i in range(n):
        dice = rng.integers(0, 10)
        if dice < 8:
            mate_chrom_ids[i] = own_chrom_ids[i]
            mate_positions[i] = own_positions[i] + rng.integers(-500, 500)
        elif dice < 9:
            mate_chrom_ids[i] = (int(own_chrom_ids[i]) + 1) % 24
            mate_positions[i] = rng.integers(0, 100_000_000)
        else:
            mate_chrom_ids[i] = -1
            mate_positions[i] = 0
    return mate_chrom_ids, mate_positions, template_lengths, own_chrom_ids, own_positions


@pytest.mark.parametrize("n", [1, 100, 10_000, 100_000])
def test_round_trip(n):
    mc, mp, ts, oc, op = _make_record_set(n)
    encoded = miv2.encode(mc, mp, ts, oc, op)
    assert isinstance(encoded, bytes)
    assert encoded[:4] == b"MIv2"

    mc2, mp2, ts2 = miv2.decode(encoded, oc, op, n_records=n)
    np.testing.assert_array_equal(mc, mc2)
    np.testing.assert_array_equal(mp, mp2)
    np.testing.assert_array_equal(ts, ts2)


def test_empty_input():
    mc = np.array([], dtype=np.int32)
    mp = np.array([], dtype=np.int64)
    ts = np.array([], dtype=np.int32)
    oc = np.array([], dtype=np.uint16)
    op = np.array([], dtype=np.int64)
    encoded = miv2.encode(mc, mp, ts, oc, op)
    mc2, mp2, ts2 = miv2.decode(encoded, oc, op, n_records=0)
    assert len(mc2) == 0


def test_invalid_mate_chrom_rejected():
    mc = np.array([-2], dtype=np.int32)
    mp = np.array([0], dtype=np.int64)
    ts = np.array([0], dtype=np.int32)
    oc = np.array([0], dtype=np.uint16)
    op = np.array([0], dtype=np.int64)
    with pytest.raises(ValueError, match="invalid mate_chrom_id"):
        miv2.encode(mc, mp, ts, oc, op)
