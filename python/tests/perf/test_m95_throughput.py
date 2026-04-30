"""M95 DELTA_RANS throughput regression smoke.

Marked ``perf`` so it doesn't run in the default pytest pass; opt-in via
``pytest -m perf``. Asserts a conservative lower bound on the Python
encoder and decoder.

Input: 1.25M sorted ascending int64 positions, LCG seed 0xBEEF, deltas
100-500 (~10 MiB raw). Matches the V10 harness bench_codecs_genomic
workload.

Run::

    pytest python/tests/perf/test_m95_throughput.py -v -s -m perf
"""
from __future__ import annotations

import struct
import time

import pytest

from ttio.codecs.delta_rans import decode as delta_rans_decode
from ttio.codecs.delta_rans import encode as delta_rans_encode

MIN_ENCODE_MBPS = 1.0
MIN_DECODE_MBPS = 1.0


def _build_sorted_positions(n: int) -> bytes:
    """1.25M sorted ascending int64, LCG deltas 100-500."""
    values = []
    pos = 1000
    s = 0xBEEF
    mask64 = (1 << 64) - 1
    for _ in range(n):
        values.append(pos)
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        delta = 100 + ((s >> 32) % 401)
        pos += delta
    return struct.pack(f"<{n}q", *values)


@pytest.mark.perf
def test_delta_rans_encode_decode_throughput(capsys):
    """Encode+decode 1.25M sorted int64 positions (~10 MiB)."""
    n = 1_250_000
    raw = _build_sorted_positions(n)
    raw_mb = len(raw) / 1e6

    t0 = time.perf_counter()
    encoded = delta_rans_encode(raw, 8)
    t_enc = time.perf_counter() - t0

    t1 = time.perf_counter()
    decoded = delta_rans_decode(encoded)
    t_dec = time.perf_counter() - t1

    enc_mbps = raw_mb / t_enc if t_enc > 0 else float("inf")
    dec_mbps = raw_mb / t_dec if t_dec > 0 else float("inf")
    ratio = len(encoded) / len(raw)

    with capsys.disabled():
        print(
            f"\n[m95 perf] {n:,} int64 positions, "
            f"{raw_mb:.1f}MB raw -> {len(encoded)/1e6:.2f}MB encoded "
            f"({ratio:.3f}x ratio)"
        )
        print(
            f"  encode {enc_mbps:.1f} MB/s ({t_enc:.2f}s), "
            f"decode {dec_mbps:.1f} MB/s ({t_dec:.2f}s)"
        )

    assert decoded == raw, "round-trip mismatch"
    assert enc_mbps >= MIN_ENCODE_MBPS, (
        f"DELTA_RANS encode at {enc_mbps:.1f} MB/s, need >={MIN_ENCODE_MBPS} MB/s"
    )
    assert dec_mbps >= MIN_DECODE_MBPS, (
        f"DELTA_RANS decode at {dec_mbps:.1f} MB/s, need >={MIN_DECODE_MBPS} MB/s"
    )
