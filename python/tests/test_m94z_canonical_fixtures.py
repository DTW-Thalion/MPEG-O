"""Generate-and-validate the M94.Z canonical conformance fixtures.

Mirrors ``test_m94_canonical_fixtures.py`` for the new M94.Z codec.
On first run (or when a fixture file is absent), it WRITES the fixture.
On subsequent runs, it VALIDATES that ``encode(...)`` still produces
byte-identical fixtures.

Per spec §10 of the M94.Z design doc, these fixtures are the cross-
language byte-exact contract. Future ObjC and Java ports of M94.Z will
``decode(read_fixture("m94z_a.bin"))`` and verify byte-exact
reconstruction.

Generators (a..d, f..h) mirror the M94 v1 fixture roster — same input
definitions, just routed through the M94.Z codec.
"""
from __future__ import annotations

import random
from pathlib import Path

import pytest

from ttio.codecs.fqzcomp_nx16_z import (
    decode_with_metadata,
    encode,
)

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "codecs"


def _fixture_a():
    """All Q40 — 100 reads × 100bp."""
    n_reads = 100
    read_len = 100
    qualities = bytes([40 + 33] * (n_reads * read_len))
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


def _fixture_f():
    """80% reverse-complement — revcomp context exercise, seed 0xF00D."""
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
    """Renormalisation boundary — single 5000-byte read, all Q35.

    Same input shape as M94 v1 fixture g; under M94.Z's static-per-block
    model the freq table is built once and the rANS pass uses it
    unchanged, so this fixture exercises the encode path on a
    high-redundancy single-read input.
    """
    n_bytes = 5000
    qualities = bytes([35 + 33] * n_bytes)
    return qualities, [n_bytes], [0]


def _fixture_h():
    """Single-symbol saturation — 50000 bytes all Q40, single read."""
    n_bytes = 50_000
    qualities = bytes([40 + 33] * n_bytes)
    return qualities, [n_bytes], [0]


FIXTURE_GENERATORS = [
    ("m94z_a.bin", _fixture_a),
    ("m94z_b.bin", _fixture_b),
    ("m94z_c.bin", _fixture_c),
    ("m94z_d.bin", _fixture_d),
    ("m94z_f.bin", _fixture_f),
    ("m94z_g.bin", _fixture_g),
    ("m94z_h.bin", _fixture_h),
]


@pytest.mark.parametrize("fname,gen", FIXTURE_GENERATORS)
def test_fixture_round_trips_and_matches_committed_bytes(fname, gen):
    qualities, read_lengths, revcomp_flags = gen()
    # The committed M94.Z canonical fixtures were generated under the V3
    # (adaptive Range Coder) wire format. Post-L2.X Stage 2 the no-override
    # default is V4 (CRAM 3.1 fqzcomp_qual port) — so fixture generation
    # must explicitly opt out of V4 to keep the committed bytes stable.
    # V4 fixtures will be added in a separate task.
    encoded = encode(
        qualities, read_lengths, revcomp_flags, prefer_v4=False,
    )

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
