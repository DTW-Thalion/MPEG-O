"""Generate-and-validate the M94 FQZCOMP_NX16 canonical conformance fixtures.

Dual-purpose test mirroring M93's pattern:
  - On first run (or when a fixture file is absent), it WRITES the fixture.
  - On subsequent runs, it VALIDATES that ``encode(...)`` still produces
    byte-identical fixtures — guarding against accidental wire-format
    drift in the Python reference implementation.

ObjC and Java tests then ``decode(read_fixture("fqzcomp_nx16_a.bin"))``
and verify byte-exact reconstruction.

The 8 fixtures cover (per spec §3 M94, fixture roster):
  a — all Q40           (highest-redundancy / tightest compression case)
  b — Illumina profile  (Q30 mean, Q20-Q40 range, deterministic seed)
  c — PacBio HiFi       (Q40 majority, Q30-Q60 range)
  d — 4-read minimum    (4-way rANS edge case)
  e — 1M reads × 100bp  (large-volume validation)
  f — 80% revcomp       (revcomp context exercise)
  g — renorm boundary   (engineered to fire renorm at step 256)
  h — symbol freq saturation
"""
from __future__ import annotations

import random
from pathlib import Path

import pytest

from ttio.codecs.fqzcomp_nx16 import (
    decode_with_metadata,
    encode,
)

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "codecs"


# Fixtures (a)–(h) per spec §3 M94. Each returns
# (qualities, read_lengths, revcomp_flags) suitable for encode().


def _fixture_a():
    """All Q40 — 100 reads × 100bp."""
    n_reads = 100
    read_len = 100
    qualities = bytes([40 + 33] * (n_reads * read_len))  # b"I" * 10000
    read_lengths = [read_len] * n_reads
    revcomp_flags = [0] * n_reads
    return qualities, read_lengths, revcomp_flags


def _fixture_b():
    """Typical Illumina profile — Q30 mean, Q20-Q40 range, seed 0xBEEF."""
    rng = random.Random(0xBEEF)
    n_reads = 100
    read_len = 100
    quals = bytearray()
    for _ in range(n_reads * read_len):
        q = max(20, min(40, int(rng.gauss(30, 5))))
        quals.append(q + 33)
    return bytes(quals), [read_len] * n_reads, [0] * n_reads


def _fixture_c():
    """PacBio HiFi profile — Q40 majority, Q30-Q60 range, seed 0xCAFE."""
    rng = random.Random(0xCAFE)
    n_reads = 50
    read_len = 100
    quals = bytearray()
    for _ in range(n_reads * read_len):
        # 70% Q40, 30% Q30-Q60.
        if rng.random() < 0.7:
            q = 40
        else:
            q = rng.randrange(30, 61)
        quals.append(q + 33)
    return bytes(quals), [read_len] * n_reads, [0] * n_reads


def _fixture_d():
    """Edge — 4 reads × 100bp (smallest valid 4-way input)."""
    rng = random.Random(0xDEAD)
    qualities = bytes(rng.randrange(33, 74) for _ in range(4 * 100))
    return qualities, [100] * 4, [0, 1, 0, 1]


def _fixture_e():
    """Large volume — 1M reads × 100bp at uniform Q30 (commit binary)."""
    n_reads = 1_000_000
    read_len = 100
    qualities = bytes([30 + 33] * (n_reads * read_len))
    return qualities, [read_len] * n_reads, [0] * n_reads


def _fixture_f():
    """80% reverse-complement — revcomp context exercise."""
    rng = random.Random(0xF00D)
    n_reads = 100
    read_len = 100
    quals = bytearray()
    for _ in range(n_reads * read_len):
        q = max(20, min(40, int(rng.gauss(30, 5))))
        quals.append(q + 33)
    revcomp_flags = [1 if rng.random() < 0.8 else 0 for _ in range(n_reads)]
    return bytes(quals), [read_len] * n_reads, revcomp_flags


def _fixture_g():
    """Renormalisation boundary — engineered to fire renorm in one
    context at exactly the canonical step.

    With LEARNING_RATE=16, MAX_COUNT=4096, initial count[s]=1, each
    update on a single symbol grows that count by 16. After update N,
    count[s] = 1 + 16*N. count[s] > 4096 when 1 + 16*N > 4096, i.e.
    N >= 256. So the 256th update on a single symbol triggers renorm.

    To fire renorm in one context, we craft an input where the same
    context is hit 256+ times with the same symbol. Use a single
    short read with constant qualities — every byte position-bucket
    differs but the read flag/length stays the same; for the test
    we use a single read of 1024 bytes with a single Q value (the
    pos_bucket varies through 16 buckets). This causes 16 contexts
    to each see ~64 same-symbol hits (NOT enough for renorm at 256
    in any one context). Instead use 256 short reads of 1 byte each
    with the same symbol — 256 different first-position contexts,
    each getting a single hit. Still no renorm. So we need ONE context
    hit 256+ times: a single read of 5000 bytes (pos buckets cycle
    through 16, so each bucket gets ~312 hits — RENORM FIRES on bucket
    where 256th hit lands).
    """
    n_bytes = 5000
    qualities = bytes([35 + 33] * n_bytes)
    return qualities, [n_bytes], [0]


def _fixture_h():
    """Symbol freq saturation — single symbol drives one context's
    freq table to repeated halving.

    Single read of 50_000 bytes all Q40 → first context sees ~3125 hits
    (since pos_bucket cycles 16 ways, each bucket gets ~3125 hits). At
    16 hits/cycle that's ~50_000/16 = 3125 renorm cycles per bucket;
    well past saturation.
    """
    n_bytes = 50_000
    qualities = bytes([40 + 33] * n_bytes)
    return qualities, [n_bytes], [0]


FIXTURE_GENERATORS = [
    ("fqzcomp_nx16_a.bin", _fixture_a),
    ("fqzcomp_nx16_b.bin", _fixture_b),
    ("fqzcomp_nx16_c.bin", _fixture_c),
    ("fqzcomp_nx16_d.bin", _fixture_d),
    pytest.param(
        "fqzcomp_nx16_e.bin", _fixture_e,
        marks=pytest.mark.slow,
    ),
    ("fqzcomp_nx16_f.bin", _fixture_f),
    ("fqzcomp_nx16_g.bin", _fixture_g),
    ("fqzcomp_nx16_h.bin", _fixture_h),
]


@pytest.mark.parametrize("fname,gen", FIXTURE_GENERATORS)
def test_fixture_round_trips_and_matches_committed_bytes(fname, gen):
    qualities, read_lengths, revcomp_flags = gen()
    encoded = encode(qualities, read_lengths, revcomp_flags)

    fpath = FIXTURES_DIR / fname
    if not fpath.exists():
        FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
        fpath.write_bytes(encoded)
        pytest.skip(f"wrote new fixture {fname} — re-run to validate")

    committed = fpath.read_bytes()
    assert encoded == committed, (
        f"{fname}: encode() produces different bytes than the committed "
        f"fixture ({len(encoded)} encoded vs {len(committed)} committed). "
        f"If this is intentional (wire-format change), delete the fixture "
        f"and re-run; otherwise investigate the regression."
    )

    decoded_q, decoded_rl, _ = decode_with_metadata(
        encoded, revcomp_flags=revcomp_flags,
    )
    assert decoded_q == qualities
    assert decoded_rl == read_lengths
