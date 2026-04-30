"""Unit tests for M94.Z (CRAM-mimic FQZCOMP_NX16) — components & smallest round-trip.

Phase 1 verification per spec
``docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md``.
"""
from __future__ import annotations

import pytest

from ttio.codecs.fqzcomp_nx16_z import (
    B,
    B_BITS,
    L,
    MAGIC,
    NUM_STREAMS,
    T,
    T_BITS,
    VERSION,
    X_MAX_PREFACTOR,
    ContextParams,
    cumulative,
    decode_with_metadata,
    encode,
    m94z_context,
    normalise_to_total,
    position_bucket_pbits,
)


# ── Algorithm constants (spec §1) ──────────────────────────────────────


def test_algorithm_constants_match_spec():
    assert L == 1 << 15
    assert B_BITS == 16
    assert B == 1 << 16
    assert T == 1 << 12
    assert T_BITS == 12
    assert NUM_STREAMS == 4
    assert MAGIC == b"M94Z"
    assert VERSION == 1
    # b * L = 2^31
    assert B * L == 1 << 31
    # x_max prefactor = (L >> T_BITS) << B_BITS = 2^3 * 2^16 = 2^19
    assert X_MAX_PREFACTOR == 1 << 19
    # T must divide b*L exactly (spec §2.4 invariant).
    assert (B * L) % T == 0


# ── Frequency normalisation ────────────────────────────────────────────


def test_normalise_uniform_to_T():
    counts = [4] * 256
    freq = normalise_to_total(counts, T)
    assert sum(freq) == T
    # Uniform 256-symbol → each freq = 16.
    assert all(f == 16 for f in freq)


def test_normalise_single_symbol_gets_all_total():
    counts = [0] * 256
    counts[42] = 100
    freq = normalise_to_total(counts, T)
    assert sum(freq) == T
    assert freq[42] == T
    assert all(freq[i] == 0 for i in range(256) if i != 42)


def test_normalise_preserves_floor_one():
    """Symbols with raw_count >= 1 must have freq[s] >= 1."""
    counts = [0] * 256
    counts[0] = 1_000_000
    counts[1] = 1
    counts[255] = 1
    freq = normalise_to_total(counts, T)
    assert sum(freq) == T
    assert freq[0] > 0
    assert freq[1] >= 1
    assert freq[255] >= 1
    assert freq[5] == 0  # zero-count stays zero


def test_normalise_zero_counts_yields_degenerate_distribution():
    counts = [0] * 256
    freq = normalise_to_total(counts, T)
    assert sum(freq) == T
    assert freq[0] == T


def test_normalise_sums_to_total_for_random_inputs():
    import random
    rng = random.Random(0xC0DE)
    for _ in range(200):
        n_distinct = rng.randint(1, 256)
        counts = [0] * 256
        for _ in range(rng.randint(n_distinct, 5000)):
            counts[rng.randrange(256)] += 1
        freq = normalise_to_total(counts, T)
        assert sum(freq) == T
        for s in range(256):
            if counts[s] > 0:
                assert freq[s] >= 1


def test_cumulative_is_prefix_sum():
    freq = [0] * 256
    freq[10] = 100
    freq[20] = 200
    freq[30] = 700
    assert sum(freq) == 1000
    cum = cumulative(freq)
    assert cum[0] == 0
    assert cum[10] == 0
    assert cum[11] == 100
    assert cum[20] == 100
    assert cum[21] == 300
    assert cum[31] == 1000
    assert cum[256] == 1000


# ── Context bit-pack (spec §4.2) ──────────────────────────────────────


def test_context_default_dimensions_fit_in_sloc():
    # Defaults: qbits=12, pbits=2, sloc=14 → mask 0x3FFF.
    smask = (1 << 14) - 1
    for _ in range(50):
        ctx = m94z_context(prev_q=0xABC, pos_bucket=3, revcomp=1)
        assert 0 <= ctx <= smask


def test_context_zero_input_is_zero():
    assert m94z_context(0, 0, 0) == 0


def test_context_changes_with_inputs():
    ctxs = set()
    for prev_q in (0, 1, 0x7FF, 0xFFF):
        for pb in range(4):
            for rc in (0, 1):
                ctxs.add(m94z_context(prev_q, pb, rc))
    # Should have many distinct values (not always — masking may collide
    # but for these inputs we get plenty of variety).
    assert len(ctxs) > 4


def test_position_bucket_edge_cases():
    # Empty / negative read_length → 0.
    assert position_bucket_pbits(0, 0, 2) == 0
    assert position_bucket_pbits(50, 0, 2) == 0
    # position past end → max bucket.
    assert position_bucket_pbits(100, 100, 2) == 3
    assert position_bucket_pbits(99, 100, 2) == 3
    # quartile mapping for read_length=100, pbits=2 → 4 buckets of 25.
    assert position_bucket_pbits(0, 100, 2) == 0
    assert position_bucket_pbits(24, 100, 2) == 0
    assert position_bucket_pbits(25, 100, 2) == 1
    assert position_bucket_pbits(50, 100, 2) == 2
    assert position_bucket_pbits(75, 100, 2) == 3


# ── Smallest round-trip (spec §1.A acceptance check) ──────────────────


def test_smallest_round_trip_uniform_q30():
    """4 reads × 100 bp uniform Q30 — minimum case."""
    qualities = b"?" * 400  # Q30 + 33 = 63 = '?'
    rls = [100, 100, 100, 100]
    rfs = [0, 1, 0, 1]
    blob = encode(qualities, rls, rfs)
    decoded, drls, drfs = decode_with_metadata(blob, revcomp_flags=rfs)
    assert decoded == qualities
    assert drls == rls
    assert drfs == rfs
    # Header magic
    assert blob[:4] == MAGIC


def test_round_trip_single_read_single_quality():
    """1 read × 100 bp, all same quality — heaviest-redundancy case."""
    qualities = b"I" * 100  # Q40 + 33
    rls = [100]
    rfs = [0]
    blob = encode(qualities, rls, rfs)
    decoded, _, _ = decode_with_metadata(blob, revcomp_flags=rfs)
    assert decoded == qualities


def test_round_trip_n_padding_zero():
    """n divisible by 4 — no padding."""
    qualities = bytes(range(60, 60 + 12))
    rls = [12]
    rfs = [0]
    blob = encode(qualities, rls, rfs)
    decoded, _, _ = decode_with_metadata(blob, revcomp_flags=rfs)
    assert decoded == qualities


def test_round_trip_n_needs_padding():
    """n not divisible by 4 — exercises the pad_count flag."""
    for length in (1, 2, 3, 5, 7, 9, 11, 13):
        qualities = bytes((40 + 33,) * length)
        rls = [length]
        rfs = [0]
        blob = encode(qualities, rls, rfs)
        decoded, _, _ = decode_with_metadata(blob, revcomp_flags=rfs)
        assert decoded == qualities, f"failed at length {length}"


def test_round_trip_with_revcomp_variation():
    """Mixed revcomp flags exercise the revcomp context bit."""
    qualities = b"?" * 800
    rls = [100] * 8
    rfs = [0, 1, 1, 0, 0, 1, 0, 1]
    blob = encode(qualities, rls, rfs)
    decoded, _, drfs = decode_with_metadata(blob, revcomp_flags=rfs)
    assert decoded == qualities
    assert drfs == rfs


def test_decode_default_revcomp_when_none_supplied():
    """When revcomp_flags=None, decoder uses all-zero. Encoder must
    have used same when encoding (so we test that path by encoding
    with all-zero rfs)."""
    qualities = b"5" * 200  # Q20 + 33
    rls = [50] * 4
    rfs = [0] * 4
    blob = encode(qualities, rls, rfs)
    decoded, _, _ = decode_with_metadata(blob, revcomp_flags=None)
    assert decoded == qualities


def test_decode_rejects_wrong_magic():
    qualities = b"?" * 4
    rls = [4]
    rfs = [0]
    blob = bytearray(encode(qualities, rls, rfs))
    blob[:4] = b"XXXX"
    with pytest.raises(ValueError, match="bad magic"):
        decode_with_metadata(bytes(blob))


def test_decode_rejects_wrong_revcomp_length():
    qualities = b"?" * 100
    rls = [100]
    rfs = [0]
    blob = encode(qualities, rls, rfs)
    with pytest.raises(ValueError, match="revcomp_flags"):
        decode_with_metadata(blob, revcomp_flags=[0, 1])


def test_encode_validates_input_lengths():
    with pytest.raises(ValueError):
        # sum(read_lengths) != len(qualities)
        encode(b"AAA", [10], [0])
    with pytest.raises(ValueError):
        # len(read_lengths) != len(revcomp_flags)
        encode(b"AAA", [3], [0, 1])


def test_cython_and_python_paths_are_byte_exact():
    """The Cython encode kernel must produce byte-identical output to
    the pure-Python reference (byte-exact contract per spec §10).
    """
    import ttio.codecs.fqzcomp_nx16_z as m

    if not m._HAVE_C_EXTENSION:
        pytest.skip("Cython extension not built")

    inputs = [
        # All-Q40, 100×100bp, no revcomp
        (bytes([40 + 33] * 10000), [100] * 100, [0] * 100),
        # Mixed, 50×100bp, alternating revcomp
        (
            bytes(((i * 7 + 13) % 60 + 33) for i in range(50 * 100)),
            [100] * 50,
            [i & 1 for i in range(50)],
        ),
        # Single small read
        (bytes([35 + 33] * 100), [100], [0]),
        # Padding-required input (length not divisible by 4)
        (bytes([35 + 33] * 50), [50], [0]),
    ]

    for q, rl, rf in inputs:
        # Encode via Cython.
        b_cython = m.encode(q, rl, rf)
        # Encode via pure Python.
        m._HAVE_C_EXTENSION = False
        b_python = m.encode(q, rl, rf)
        m._HAVE_C_EXTENSION = True
        assert b_cython == b_python, (
            f"Cython vs Python encode bytes diverge "
            f"(len={len(q)}, n_reads={len(rl)})"
        )
