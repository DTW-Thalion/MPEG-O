"""Regenerate tests/fixtures/genomic/m86_codec_cigars_name_tokenized.tio.

Run from repo root:
    python python/tests/fixtures/genomic/regenerate_m86_cigars_name_tokenized.py

Cross-language conformance fixture for M86 Phase C (HANDOFF.md
§6.4 Fixture B): a 100-read genomic run whose ``cigars`` channel
uses the NAME_TOKENIZED codec via the schema-lift path. ObjC and
Java construct the same input cigar list (all-uniform '100M') and
assert byte-exact decode against this Python-produced fixture.

The cigar distribution is the columnar-mode sweet spot:
- 100% '100M'  (uniform)

This is the §1.2 selection-table case where NAME_TOKENIZED's
columnar mode is at its most efficient — 1-entry dict + delta=0
on the numeric column. Other channels use the M82 baseline so
the fixture isolates the cigars schema-lift path.

Re-run only when the M86 spec changes — the committed fixture is
the cross-language byte-level contract.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

# Make ttio importable when run from the repo root.
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "src"))

from ttio.enums import Compression
from ttio.spectral_dataset import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun


N_READS = 100
READ_LEN = 100
TOTAL = N_READS * READ_LEN


def _build() -> WrittenGenomicRun:
    seq = (b"ACGT" * 25) * N_READS
    qual = bytes((30 + (i % 11)) for i in range(TOTAL))
    cigars = ["100M"] * N_READS
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86C_NT",
        positions=np.arange(N_READS, dtype=np.int64) * 1000,
        mapping_qualities=np.full(N_READS, 60, dtype=np.uint8),
        flags=np.zeros(N_READS, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(N_READS, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N_READS, READ_LEN, dtype=np.uint32),
        cigars=cigars,
        read_names=[f"r{i}" for i in range(N_READS)],
        mate_chromosomes=["chr1"] * N_READS,
        mate_positions=np.full(N_READS, -1, dtype=np.int64),
        template_lengths=np.zeros(N_READS, dtype=np.int32),
        chromosomes=["chr1"] * N_READS,
        signal_codec_overrides={
            "cigars": Compression.NAME_TOKENIZED,
        },
    )


def main() -> None:
    out = Path(__file__).parent / "m86_codec_cigars_name_tokenized.tio"
    SpectralDataset.write_minimal(
        out,
        title="m86-cigars-name-tokenized-cross-lang-fixture",
        isa_investigation_id="ISA-M86C-100",
        runs={},
        genomic_runs={"genomic_0001": _build()},
    )
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
