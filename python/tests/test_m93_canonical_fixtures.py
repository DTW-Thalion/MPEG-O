"""Generate-and-validate the M93 REF_DIFF canonical conformance fixtures.

This test serves a dual purpose:
  - On first run (or when fixtures are absent), it WRITES the fixtures.
  - On subsequent runs, it VALIDATES that ``encode(...)`` still produces
    byte-identical fixtures — guarding against accidental wire-format
    drift in the Python reference implementation.

ObjC and Java tests then ``decode(read_fixture("ref_diff_a.bin"))`` and
verify byte-exact reconstruction.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from ttio.codecs.ref_diff import encode, decode

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "codecs"


def _ref_diff_fixture_a():
    """All matches — 100 reads of 100bp pure-ACGT against same ref."""
    ref = b"ACGT" * 250  # 1000bp
    sequences = [b"ACGTACGTAC" * 10] * 100   # all match ref[0..99]
    cigars = ["100M"] * 100
    positions = [1] * 100
    return sequences, cigars, positions, ref, hashlib.md5(ref).digest(), "fixture_a_uri"


def _ref_diff_fixture_b():
    """Sparse substitutions — vary one base per read across 200 reads."""
    ref = b"ACGT" * 250
    base = bytearray(b"ACGTACGTAC" * 10)
    sequences = []
    for i in range(200):
        s = bytearray(base)
        # Touch one position per read (rotate through the array).
        idx = i % 100
        s[idx] = ord("C") if base[idx] != ord("C") else ord("G")
        sequences.append(bytes(s))
    cigars = ["100M"] * 200
    positions = [1] * 200
    return sequences, cigars, positions, ref, hashlib.md5(ref).digest(), "fixture_b_uri"


def _ref_diff_fixture_c():
    """Heavy indels + soft-clips — cycles through 3 cigar shapes."""
    ref = b"ACGTACGTAC" * 100
    # 2S10M, 4M2I6M, 5M2D5M each repeated 10×
    sequences_template = [
        # 2S10M: NN | ACGTACGTAC = 12 bytes total
        b"NN" + b"ACGTACGTAC",
        # 4M2I6M: ACGT | NN | ACGTAC (note: ref consumed by M ops only,
        # so M-walks cover ref[0..3] then ref[4..9]). Read length = 12.
        b"ACGT" + b"NN" + b"ACGTAC",
        # 5M2D5M: 10 read bases, ref-walks 12 long.
        # ref[0..4]=ACGTA matches first M; ref[7..11]=GTACG matches second.
        b"ACGTA" + b"GTACG",
    ]
    cigars_template = ["2S10M", "4M2I6M", "5M2D5M"]
    sequences = sequences_template * 10
    cigars = cigars_template * 10
    positions = [1] * 30
    return sequences, cigars, positions, ref, hashlib.md5(ref).digest(), "fixture_c_uri"


def _ref_diff_fixture_d():
    """Edge cases: single-read, single-base."""
    ref = b"ACGT" * 1000
    sequences = [b"A"]
    cigars = ["1M"]
    positions = [1]
    return sequences, cigars, positions, ref, hashlib.md5(ref).digest(), "fixture_d_uri"


FIXTURE_GENERATORS = [
    ("ref_diff_a.bin", _ref_diff_fixture_a),
    ("ref_diff_b.bin", _ref_diff_fixture_b),
    ("ref_diff_c.bin", _ref_diff_fixture_c),
    ("ref_diff_d.bin", _ref_diff_fixture_d),
]


@pytest.mark.parametrize("fname,gen", FIXTURE_GENERATORS)
def test_fixture_round_trips_and_matches_committed_bytes(fname, gen, request):
    sequences, cigars, positions, ref, md5, uri = gen()
    encoded = encode(sequences, cigars, positions, ref, md5, uri)

    fpath = FIXTURES_DIR / fname
    if not fpath.exists():
        FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
        fpath.write_bytes(encoded)
        # Skip on the write-pass so a fresh checkout's first run doesn't
        # falsely pass without exercising the validator.
        pytest.skip(f"wrote new fixture {fname} — re-run to validate")

    committed = fpath.read_bytes()
    assert encoded == committed, (
        f"{fname}: encode() produces different bytes than the committed "
        f"fixture ({len(encoded)} encoded vs {len(committed)} committed). "
        f"If this is intentional (wire-format change), delete the fixture "
        f"and re-run; otherwise investigate the regression."
    )

    # Always verify round-trip on the encoded bytes.
    decoded = decode(encoded, cigars, positions, ref)
    assert decoded == sequences
