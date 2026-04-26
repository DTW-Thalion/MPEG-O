"""Regenerate tests/fixtures/genomic/m86_codec_mate_info_full.tio.

Run from repo root:
    python python/tests/fixtures/genomic/regenerate_m86_mate_info_full.py

Cross-language conformance fixture for M86 Phase F (HANDOFF.md
§6.4): a 100-read genomic run whose ``mate_info`` channel uses
the Phase F subgroup layout with all three per-field overrides at
their recommended codec choices:

- ``mate_info_chrom``: NAME_TOKENIZED (chromosome alphabet is
  tiny and highly repetitive)
- ``mate_info_pos``:   RANS_ORDER1
- ``mate_info_tlen``:  RANS_ORDER1

ObjC and Java construct the same input mate distributions from
the same generator and assert byte-exact decode against this
Python-produced fixture.

The mate distributions are realistic for paired-end Illumina:
- chrom: 90 chr1, 5 chr2, 3 chrX, 2 unmapped ("*")
- pos:   monotonic positions for paired mates, -1 for unmapped
- tlen:  cluster around 350 (typical insert size) for paired,
         0 for unmapped

Other channels use the M82 baseline (no codec overrides) so the
fixture isolates the mate_info schema-lift path.

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


def _mate_chroms() -> list[str]:
    return ["chr1"] * 90 + ["chr2"] * 5 + ["chrX"] * 3 + ["*"] * 2


def _mate_positions() -> np.ndarray:
    chroms = _mate_chroms()
    out = np.empty(N_READS, dtype=np.int64)
    for i, c in enumerate(chroms):
        out[i] = -1 if c == "*" else (i * 100 + 500)
    return out


def _mate_tlens() -> np.ndarray:
    chroms = _mate_chroms()
    out = np.empty(N_READS, dtype=np.int32)
    for i, c in enumerate(chroms):
        out[i] = 0 if c == "*" else (350 + (i % 11) - 5)
    return out


def _build() -> WrittenGenomicRun:
    seq = (b"ACGT" * 25) * N_READS
    qual = bytes((30 + (i % 11)) for i in range(TOTAL))
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86F_MATE",
        positions=np.arange(N_READS, dtype=np.int64) * 1000,
        mapping_qualities=np.full(N_READS, 60, dtype=np.uint8),
        flags=np.zeros(N_READS, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(N_READS, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N_READS, READ_LEN, dtype=np.uint32),
        cigars=["100M"] * N_READS,
        read_names=[f"r{i}" for i in range(N_READS)],
        mate_chromosomes=_mate_chroms(),
        mate_positions=_mate_positions(),
        template_lengths=_mate_tlens(),
        chromosomes=["chr1"] * N_READS,
        signal_codec_overrides={
            "mate_info_chrom": Compression.NAME_TOKENIZED,
            "mate_info_pos":   Compression.RANS_ORDER1,
            "mate_info_tlen":  Compression.RANS_ORDER1,
        },
    )


def main() -> None:
    out = Path(__file__).parent / "m86_codec_mate_info_full.tio"
    SpectralDataset.write_minimal(
        out,
        title="m86-mate-info-full-cross-lang-fixture",
        isa_investigation_id="ISA-M86F-100",
        runs={},
        genomic_runs={"genomic_0001": _build()},
    )
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
