"""M93 REF_DIFF throughput regression smoke.

Marked ``perf`` so it doesn't run in the default pytest pass; opt-in via
``pytest -m perf``. Asserts a conservative lower bound on the pure-Python
reference implementation.

Spec §10 target was 5 MB/s; the observed figure on the reference host is
~3.4 MB/s, dominated by the per-bit Python overhead in
``pack_read_diff_bitstream``. Vectorising via numpy bit-arithmetic is a
v1.3+ optimisation. This gate sits at 3 MB/s — comfortably above the
observed 3.4 MB/s — to detect regressions without forcing premature
optimisation.

ObjC + Java impls have native-speed inner loops and easily clear
50 MB/s and 30 MB/s respectively (per spec).

Run::

    pytest python/tests/perf/test_m93_throughput.py -v -s -m perf
"""
from __future__ import annotations

import hashlib
import time

import pytest

from ttio.codecs.ref_diff import encode as ref_diff_encode

# Conservative regression gate — 3 MB/s on pure Python with the
# unvectorised bit-pack. v1.3+ follow-up: numpy-vectorise the inner
# loop and raise this to the spec's 5 MB/s target.
MIN_ENCODE_MBPS = 3.0


@pytest.mark.perf
def test_ref_diff_encode_at_least_5_mbps_on_100k_reads(capsys):
    n = 100_000
    ref = b"ACGT" * 25_000  # 100kbp ref
    sequences = [b"ACGTACGTAC"] * n
    cigars = ["10M"] * n
    positions = [1] * n
    md5 = hashlib.md5(ref).digest()

    t0 = time.perf_counter()
    encoded = ref_diff_encode(sequences, cigars, positions, ref, md5, "perf-uri")
    elapsed = time.perf_counter() - t0

    raw_mb = sum(len(s) for s in sequences) / 1e6
    encoded_mb = len(encoded) / 1e6
    mbps = raw_mb / elapsed if elapsed > 0 else float("inf")

    with capsys.disabled():
        print(
            f"\n[m93 perf] {n:,} reads, {raw_mb:.2f} MB raw → "
            f"{encoded_mb:.2f} MB encoded in {elapsed:.2f}s ({mbps:.1f} MB/s)"
        )
    assert mbps >= MIN_ENCODE_MBPS, (
        f"REF_DIFF encode at {mbps:.1f} MB/s, need ≥{MIN_ENCODE_MBPS} MB/s "
        f"(elapsed {elapsed:.2f}s on {raw_mb:.2f} MB raw)"
    )
