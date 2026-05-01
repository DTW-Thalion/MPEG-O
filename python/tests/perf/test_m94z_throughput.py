"""M94.Z FQZCOMP_NX16_Z throughput regression smoke.

Marked ``perf`` so it doesn't run in the default pytest pass; opt-in via
``pytest -m perf``. Asserts a conservative lower bound on the
Cython-accelerated Python encoder and decoder.

Input: 100K reads x 100bp Q20-Q40 (ASCII 53-73) via PCG-like LCG seeded
0xBEEF — byte-identical to the ObjC perf test (TestM94ZFqzcompPerf.m) for
cross-language parity comparison.

Run::

    pytest python/tests/perf/test_m94z_throughput.py -v -s -m perf
"""
from __future__ import annotations

import time

import pytest

from ttio.codecs.fqzcomp_nx16_z import decode_with_metadata
from ttio.codecs.fqzcomp_nx16_z import encode as fqz_encode
from ttio.codecs.fqzcomp_nx16_z import get_backend_name

MIN_ENCODE_MBPS = 30.0
MIN_DECODE_MBPS = 10.0


def _build_varied_qualities(n: int) -> bytes:
    """100K x 100bp Q20-Q40 LCG — matches ObjC m94zBuildVariedQualities."""
    buf = bytearray(n)
    s = 0xBEEF
    mask64 = (1 << 64) - 1
    for i in range(n):
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        buf[i] = 33 + 20 + ((s >> 32) % 21)
    return bytes(buf)


@pytest.mark.perf
def test_m94z_encode_decode_throughput(capsys):
    """Encode+decode 100K reads x 100bp synthetic Illumina profile."""
    n_reads = 100_000
    read_len = 100
    n_qual = n_reads * read_len

    qualities = _build_varied_qualities(n_qual)
    read_lengths = [read_len] * n_reads
    revcomp_flags = [(1 if (i & 7) == 0 else 0) for i in range(n_reads)]

    backend = get_backend_name()

    t0 = time.perf_counter()
    encoded = fqz_encode(qualities, read_lengths, revcomp_flags)
    t_enc = time.perf_counter() - t0

    t1 = time.perf_counter()
    result = decode_with_metadata(encoded, revcomp_flags)
    t_dec = time.perf_counter() - t1

    decoded_q = result[0] if isinstance(result, tuple) else result

    raw_mb = n_qual / 1e6
    enc_mbps = raw_mb / t_enc if t_enc > 0 else float("inf")
    dec_mbps = raw_mb / t_dec if t_dec > 0 else float("inf")
    ratio = len(encoded) / n_qual

    with capsys.disabled():
        print(
            f"\n[m94z perf] backend={backend}, "
            f"{n_reads:,} reads x {read_len}bp, "
            f"{raw_mb:.1f}MB raw -> {len(encoded)/1e6:.2f}MB encoded "
            f"({ratio:.3f}x ratio)"
        )
        print(
            f"  encode {enc_mbps:.1f} MB/s ({t_enc:.2f}s), "
            f"decode {dec_mbps:.1f} MB/s ({t_dec:.2f}s)"
        )

    assert decoded_q == qualities, "round-trip mismatch"
    assert enc_mbps >= MIN_ENCODE_MBPS, (
        f"M94.Z encode at {enc_mbps:.1f} MB/s, need >={MIN_ENCODE_MBPS} MB/s"
    )
    assert dec_mbps >= MIN_DECODE_MBPS, (
        f"M94.Z decode at {dec_mbps:.1f} MB/s, need >={MIN_DECODE_MBPS} MB/s"
    )
