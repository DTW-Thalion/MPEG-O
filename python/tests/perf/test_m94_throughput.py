"""M94 FQZCOMP_NX16 throughput regression smoke.

Marked ``perf`` so it doesn't run in the default pytest pass; opt-in via
``pytest -m perf``. Asserts a conservative lower bound on the
Cython-accelerated Python encoder.

Spec §10 target is 30 MB/s for the Python C-ext path. The current M94 v1
implementation (per-symbol M-normalisation in Cython) measures around
~0.19 MB/s — vectorisation of ``normaliseFreqs`` is the M94.X follow-up.

The gate sits at 0.1 MB/s as a regression-only safeguard, NOT the spec
target. It guards against catastrophic regressions only.

Run::

    pytest python/tests/perf/test_m94_throughput.py -v -s -m perf
"""
from __future__ import annotations

import time

import pytest

from ttio.codecs.fqzcomp_nx16 import encode as fqzcomp_encode

# Regression gate (NOT the spec target). 0.1 MB/s is a safeguard against
# catastrophic regression from the M94 v1 baseline. Spec target is
# 30 MB/s, achieved via the planned M94.X vectorisation of
# ``normaliseFreqs``.
MIN_ENCODE_MBPS = 0.1
SPEC_TARGET_MBPS = 30.0  # informational — not enforced at this gate


@pytest.mark.perf
def test_fqzcomp_encode_meets_python_floor(capsys):
    """Encode 100K reads × 100bp synthetic Illumina profile."""
    import random

    rng = random.Random(0xBEEF)
    n_reads = 100_000
    read_len = 100
    quals = bytearray()
    for _ in range(n_reads * read_len):
        q = max(20, min(40, int(rng.gauss(30, 5))))
        quals.append(q + 33)
    qualities = bytes(quals)
    read_lengths = [read_len] * n_reads
    revcomp_flags = [0] * n_reads

    t0 = time.perf_counter()
    encoded = fqzcomp_encode(qualities, read_lengths, revcomp_flags)
    elapsed = time.perf_counter() - t0

    raw_mb = len(qualities) / 1e6
    encoded_mb = len(encoded) / 1e6
    mbps = raw_mb / elapsed if elapsed > 0 else float("inf")
    ratio = encoded_mb / raw_mb

    with capsys.disabled():
        print(
            f"\n[m94 perf] {n_reads:,} reads × {read_len}bp, "
            f"{raw_mb:.2f}MB raw → {encoded_mb:.2f}MB encoded "
            f"({ratio:.3f}× ratio) in {elapsed:.2f}s "
            f"({mbps:.2f} MB/s; spec target {SPEC_TARGET_MBPS} MB/s)"
        )
    assert mbps >= MIN_ENCODE_MBPS, (
        f"FQZCOMP_NX16 encode at {mbps:.2f} MB/s, need ≥{MIN_ENCODE_MBPS} MB/s "
        f"(elapsed {elapsed:.2f}s on {raw_mb:.2f} MB raw)"
    )
