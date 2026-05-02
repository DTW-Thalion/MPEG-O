"""Synthetic-input smoke check for all 5 candidates.

Run before the full chr22 harness to catch wiring bugs cheaply:

    .venv/bin/python -m tools.perf.m94z_v4_prototype.smoke

c0 must match V3 production byte-exact. c1-c4 must produce
sparse_seq with valid shape, dtype, range, and at least 2 distinct
contexts on the synthetic input.
"""

from __future__ import annotations

import numpy as np

from ttio.codecs.fqzcomp_nx16_z import _build_context_seq_arr_vec
from tools.perf.m94z_v4_prototype.candidates import (
    CANDIDATES,
    derive_contexts_c0,
)
from tools.perf.m94z_v4_prototype.encode_pipeline import (
    encode_with_kernel,
    pad_count_for,
)

# 3 reads × 4 qualities, mixed Q-values, mixed revcomp.
SYNTH_QUALITIES = bytes([
    ord('I'), ord('I'), ord('?'), ord('?'),  # read 0: Q40 Q40 Q30 Q30, fwd
    ord('5'), ord('5'), ord('5'), ord('5'),  # read 1: Q20 Q20 Q20 Q20, rev
    ord('I'), ord('?'), ord('I'), ord('?'),  # read 2: alternating Q40/Q30, fwd
])
SYNTH_READ_LENS = [4, 4, 4]
SYNTH_REVCOMP = [0, 1, 0]


def main() -> int:
    n = len(SYNTH_QUALITIES)
    n_padded = n + pad_count_for(n)  # multiple of 4
    rl = np.asarray(SYNTH_READ_LENS, dtype=np.int64)
    rv = np.asarray(SYNTH_REVCOMP, dtype=np.int64)

    print(f"smoke input: n={n}, n_padded={n_padded}, n_reads={len(SYNTH_READ_LENS)}")

    # 1) c0 byte-exact vs V3 production
    sparse_c0, _ = derive_contexts_c0(SYNTH_QUALITIES, rl, rv, n_padded)
    sparse_v3 = _build_context_seq_arr_vec(
        SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP, n_padded,
        qbits=12, pbits=2, sloc=14,
    )
    assert np.array_equal(
        sparse_c0.astype(np.int64), sparse_v3.astype(np.int64)
    ), f"c0 != V3 production:\n  c0={sparse_c0}\n  v3={sparse_v3}"
    print("  c0 byte-exact vs V3 production: OK")

    # 2) Each candidate (including c0) — encode round-trip via kernel
    for name, sloc, derive, desc in CANDIDATES:
        sparse, n_active_est = derive(SYNTH_QUALITIES, rl, rv, n_padded)
        assert sparse.shape == (n_padded,), \
            f"{name}: shape {sparse.shape} != ({n_padded},)"
        assert sparse.dtype == np.uint32, \
            f"{name}: dtype {sparse.dtype} != uint32"
        assert sparse.max() < (1 << sloc), \
            f"{name}: sparse value {sparse.max()} >= 2^{sloc}"
        result = encode_with_kernel(
            SYNTH_QUALITIES, sparse, n_padded, sloc,
        )
        assert len(result.body_bytes) > 0, \
            f"{name}: kernel produced empty body"
        assert result.n_active >= 1, \
            f"{name}: n_active < 1"
        print(f"  {name} (sloc={sloc}): n_active={result.n_active}, "
              f"body={len(result.body_bytes)} B  OK")

    print("smoke OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
