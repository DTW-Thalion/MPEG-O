"""Regenerate tests/fixtures/genomic/m86_codec_name_tokenized.tio.

Run from repo root:
    python python/tests/fixtures/genomic/regenerate_m86_name_tokenized.py

Cross-language conformance fixture for M86 Phase E (HANDOFF.md
§6.4): a 10-read × 100-bp genomic run whose ``read_names`` channel
uses the NAME_TOKENIZED codec via the schema-lift path. ObjC and
Java construct the same input names from a deterministic generator
and assert byte-exact decode. Other channels use the M82 baseline
(no codec overrides on sequences/qualities so this fixture isolates
the read_names schema-lift path).

Re-run only when the M86 spec changes — the committed fixture is
the contract.
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


N_READS = 10
READ_LEN = 100
TOTAL = N_READS * READ_LEN


def _build() -> WrittenGenomicRun:
    seq = (b"ACGT" * 25) * N_READS
    qual = bytes((30 + (i % 11)) for i in range(TOTAL))
    # Structured Illumina-style names — same generator the ObjC and
    # Java agents use so the cross-language input is byte-identical.
    names = [
        f"INSTR:RUN:1:{i // 4}:{i % 4}:{i * 100}"
        for i in range(N_READS)
    ]
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_TEST",
        positions=np.arange(N_READS, dtype=np.int64) * 1000,
        mapping_qualities=np.full(N_READS, 60, dtype=np.uint8),
        flags=np.zeros(N_READS, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(N_READS, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N_READS, READ_LEN, dtype=np.uint32),
        cigars=["100M"] * N_READS,
        read_names=names,
        mate_chromosomes=["chr1"] * N_READS,
        mate_positions=np.full(N_READS, -1, dtype=np.int64),
        template_lengths=np.zeros(N_READS, dtype=np.int32),
        chromosomes=["chr1"] * N_READS,
        signal_codec_overrides={
            "read_names": Compression.NAME_TOKENIZED,
        },
    )


def main() -> None:
    out = Path(__file__).parent / "m86_codec_name_tokenized.tio"
    SpectralDataset.write_minimal(
        out,
        title="m86-name-tokenized-cross-lang-fixture",
        isa_investigation_id="ISA-M86E-10",
        runs={},
        genomic_runs={"genomic_0001": _build()},
    )
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
