"""Regenerate tests/fixtures/genomic/m86_codec_cigars_rans.tio.

Run from repo root:
    python python/tests/fixtures/genomic/regenerate_m86_cigars_rans.py

Cross-language conformance fixture for M86 Phase C (HANDOFF.md
§6.4 Fixture A): a 100-read genomic run whose ``cigars`` channel
uses the RANS_ORDER1 codec via the schema-lift path. ObjC and
Java construct the same input cigar list from the same generator
and assert byte-exact decode against this Python-produced fixture.

The cigar distribution is realistic mixed-WGS:
- 80% '100M'   (perfect-match)
- 10% '99M1D'  (single-base deletion)
- 10% '50M50S' (soft-clipped)

This is the §1.2 selection-table case where rANS dominates
because NAME_TOKENIZED's columnar mode falls back to verbatim
on mixed token-count input. Other channels use the M82 baseline
(no codec overrides) so the fixture isolates the cigars
schema-lift path.

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


def _mixed_cigars(n_reads: int) -> list[str]:
    """80% perfect-match, 10% deletion, 10% soft-clip. Deterministic."""
    out: list[str] = []
    for i in range(n_reads):
        m = i % 10
        if m < 8:
            out.append("100M")
        elif m == 8:
            out.append("99M1D")
        else:
            out.append("50M50S")
    return out


def _build() -> WrittenGenomicRun:
    seq = (b"ACGT" * 25) * N_READS
    qual = bytes((30 + (i % 11)) for i in range(TOTAL))
    cigars = _mixed_cigars(N_READS)
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86C_RANS",
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
            "cigars": Compression.RANS_ORDER1,
        },
    )


def main() -> None:
    out = Path(__file__).parent / "m86_codec_cigars_rans.tio"
    SpectralDataset.write_minimal(
        out,
        title="m86-cigars-rans-cross-lang-fixture",
        isa_investigation_id="ISA-M86C-100",
        runs={},
        genomic_runs={"genomic_0001": _build()},
    )
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
