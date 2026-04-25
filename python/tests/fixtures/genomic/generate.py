"""Regenerate tests/fixtures/genomic/m82_100reads.tio.

Run from repo root:
    python python/tests/fixtures/genomic/generate.py

This fixture is consumed by the M82.4 cross-language conformance
plan: ObjC and Java tests open it and assert field-level equivalence
with the Python writer's output. Re-run only when the M82 spec
changes — otherwise the committed fixture is the contract.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

# Make ttio importable when run from the repo root.
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "src"))

from ttio.spectral_dataset import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun


def _build() -> WrittenGenomicRun:
    n_reads = 100
    read_length = 150
    chromosomes_pool = ["chr1", "chr2", "chrX"]
    chroms = [chromosomes_pool[i % 3] for i in range(n_reads)]
    positions = np.array(
        [10_000 + (i // 3) * 100 for i in range(n_reads)], dtype=np.int64
    )
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapqs = np.full(n_reads, 60, dtype=np.uint8)

    rng = np.random.default_rng(42)
    bases = b"ACGT"
    seq_concat = bytes(
        rng.choice(list(bases), size=n_reads * read_length).tolist()
    )
    qual_concat = bytes([30] * (n_reads * read_length))

    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=mapqs,
        flags=flags,
        sequences=np.frombuffer(seq_concat, dtype=np.uint8),
        qualities=np.frombuffer(qual_concat, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_length,
        lengths=np.full(n_reads, read_length, dtype=np.uint32),
        cigars=[f"{read_length}M" for _ in range(n_reads)],
        read_names=[f"read_{i:06d}" for i in range(n_reads)],
        mate_chromosomes=["" for _ in range(n_reads)],
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=chroms,
    )


def main() -> None:
    out = Path(__file__).parent / "m82_100reads.tio"
    SpectralDataset.write_minimal(
        out,
        title="m82-cross-lang-fixture",
        isa_investigation_id="ISA-M82-100",
        runs={},
        genomic_runs={"genomic_0001": _build()},
    )
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
