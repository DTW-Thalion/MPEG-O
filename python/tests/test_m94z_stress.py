"""M94.Z stress test — round-trip across many input shapes.

Phase 1.B verification per spec
``docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md``.

The M94.X failure mode was sporadic byte-pairing slips at specific
``n_reads`` (1150, 3300, 4000). M94.Z's spec §2 proof guarantees
pairing for all shapes, but this test is the empirical net: every
combination MUST round-trip byte-exact.

Test matrix:
  n_reads      ∈ {10, 50, 100, 500, 1000, 1150, 2000, 3300, 4000,
                  5000, 8000, 10000, 50000, 100000}
  quality      ∈ {uniform, illumina, pacbio, random}
  read_length  ∈ {50, 100, 150, 250}
  revcomp      ∈ {all-0, all-1, alternating, random-50, random-80}

Total = 14 × 4 × 4 × 5 = 1120 combinations. Pure-Python at this scale
would take ~30 minutes for the heaviest combos; we use the ``slow``
mark to exclude very-large × non-uniform combos from the default run
and require ``pytest -m slow`` for the full sweep.
"""
from __future__ import annotations

import random

import pytest

from ttio.codecs.fqzcomp_nx16_z import (
    decode_with_metadata,
    encode,
)


N_READS_VALUES = [
    10, 50, 100, 500, 1000, 1150, 2000, 3300, 4000,
    5000, 8000, 10000, 50000, 100000,
]
QUALITY_PATTERNS = ["uniform", "illumina", "pacbio", "random"]
READ_LENGTHS = [50, 100, 150, 250]
REVCOMP_PATTERNS = ["all0", "all1", "alt", "rand50", "rand80"]


def _make_qualities(pattern: str, total: int, seed: int) -> bytes:
    rng = random.Random(seed)
    if pattern == "uniform":
        return bytes([30 + 33] * total)  # all Q30
    if pattern == "illumina":
        out = bytearray(total)
        for i in range(total):
            q = max(20, min(40, int(rng.gauss(30, 5))))
            out[i] = q + 33
        return bytes(out)
    if pattern == "pacbio":
        out = bytearray(total)
        for i in range(total):
            if rng.random() < 0.7:
                q = 40
            else:
                q = rng.randrange(30, 61)
            out[i] = q + 33
        return bytes(out)
    if pattern == "random":
        return bytes(rng.randrange(0, 60) + 33 for _ in range(total))
    raise ValueError(pattern)


def _make_revcomps(pattern: str, n_reads: int, seed: int) -> list[int]:
    rng = random.Random(seed ^ 0xCAFEBABE)
    if pattern == "all0":
        return [0] * n_reads
    if pattern == "all1":
        return [1] * n_reads
    if pattern == "alt":
        return [i & 1 for i in range(n_reads)]
    if pattern == "rand50":
        return [rng.randint(0, 1) for _ in range(n_reads)]
    if pattern == "rand80":
        return [1 if rng.random() < 0.8 else 0 for _ in range(n_reads)]
    raise ValueError(pattern)


def _is_slow_combo(n_reads: int, read_len: int, qual: str, rev: str) -> bool:
    """Mark large combos slow so default `pytest` skips them.

    Threshold: total bytes > 500_000 (so >= ~1.5s round-trip).
    """
    return n_reads * read_len > 500_000


def _round_trip_check(n_reads: int, read_len: int, qual_pattern: str,
                      rev_pattern: str) -> None:
    total = n_reads * read_len
    seed = (n_reads * 31 + read_len) ^ hash(qual_pattern) ^ hash(rev_pattern)
    qualities = _make_qualities(qual_pattern, total, seed & 0xFFFFFFFF)
    rls = [read_len] * n_reads
    rfs = _make_revcomps(rev_pattern, n_reads, seed & 0xFFFFFFFF)
    blob = encode(qualities, rls, rfs)
    decoded, drls, drfs = decode_with_metadata(blob, revcomp_flags=rfs)
    assert decoded == qualities, (
        f"M94.Z round-trip FAILED: n_reads={n_reads} read_len={read_len} "
        f"qual={qual_pattern} rev={rev_pattern} "
        f"first_diff_at={next((i for i in range(total) if i < len(decoded) and decoded[i] != qualities[i]), -1)}"
    )
    assert drls == rls
    assert drfs == rfs


# ── Default-run subset: small inputs cover all combinations of the matrix
# at n_reads ≤ 1150 (~115KB) plus the M94.X failure-mode pivots. ──────


_DEFAULT_N_READS = [10, 50, 100, 500, 1000, 1150]
_SLOW_N_READS = [2000, 3300, 4000, 5000, 8000, 10000, 50000, 100000]


@pytest.mark.parametrize("n_reads", _DEFAULT_N_READS)
@pytest.mark.parametrize("read_len", READ_LENGTHS)
@pytest.mark.parametrize("qual", QUALITY_PATTERNS)
@pytest.mark.parametrize("rev", REVCOMP_PATTERNS)
def test_round_trip_default(n_reads, read_len, qual, rev):
    if _is_slow_combo(n_reads, read_len, qual, rev):
        pytest.skip("slow combo; run with -m slow")
    _round_trip_check(n_reads, read_len, qual, rev)


@pytest.mark.slow
@pytest.mark.parametrize("n_reads", _SLOW_N_READS)
@pytest.mark.parametrize("read_len", READ_LENGTHS)
@pytest.mark.parametrize("qual", QUALITY_PATTERNS)
@pytest.mark.parametrize("rev", REVCOMP_PATTERNS)
def test_round_trip_slow(n_reads, read_len, qual, rev):
    _round_trip_check(n_reads, read_len, qual, rev)


# ── M94.X failure-mode replay (spec §8.1) ─────────────────────────────


@pytest.mark.parametrize("n_reads", [1150, 3300, 4000])
def test_m94x_failure_modes_pass_under_m94z(n_reads):
    """The M94.X codec failed at n_reads ∈ {1150, 3300, 4000}. M94.Z
    must succeed on the same shapes."""
    for read_len in (100, 150):
        for qual in ("uniform", "illumina", "pacbio", "random"):
            for rev in ("all0", "alt", "rand50"):
                _round_trip_check(n_reads, read_len, qual, rev)


# ── Edge cases ────────────────────────────────────────────────────────


@pytest.mark.parametrize("n_reads", [1, 2, 3, 4, 5])
def test_tiny_inputs(n_reads):
    """Very small input shapes (covers padding, single-stream cases)."""
    for read_len in (1, 2, 50, 100):
        for qual in ("uniform", "illumina"):
            for rev in ("all0", "all1"):
                _round_trip_check(n_reads, read_len, qual, rev)


def test_all_q40_long_single_read():
    """Single 5000-byte read all Q40 — same as fixture g."""
    qualities = bytes([40 + 33] * 5000)
    rls = [5000]
    rfs = [0]
    blob = encode(qualities, rls, rfs)
    decoded, _, _ = decode_with_metadata(blob, revcomp_flags=rfs)
    assert decoded == qualities


def test_all_q40_long_single_read_50k():
    """Single 50000-byte read all Q40 — same as fixture h."""
    qualities = bytes([40 + 33] * 50_000)
    rls = [50_000]
    rfs = [0]
    blob = encode(qualities, rls, rfs)
    decoded, _, _ = decode_with_metadata(blob, revcomp_flags=rfs)
    assert decoded == qualities
