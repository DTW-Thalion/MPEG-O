"""Regenerate the M86 codec-wiring cross-language fixtures.

Run from repo root:
    python python/tests/fixtures/genomic/regenerate_m86_basic_codecs.py

Generates the four codec-channel fixtures consumed by
:func:`test_m86_genomic_codec_wiring.test_cross_language_fixtures`:

* ``m86_codec_rans_order0.tio``    (RANS_ORDER0 on sequences + qualities)
* ``m86_codec_rans_order1.tio``    (RANS_ORDER1 on sequences + qualities)
* ``m86_codec_base_pack.tio``      (BASE_PACK on sequences + qualities)
* ``m86_codec_quality_binned.tio`` (QUALITY_BINNED on qualities only)

Re-run when the wire format changes (e.g. L1 Task #82, 2026-05-01:
``genomic_index/chromosomes`` VL-string compound replaced with
``chromosome_ids`` (uint16) + ``chromosome_names`` (compound)).
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "src"))

from ttio.enums import Compression
from ttio.spectral_dataset import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun


N_READS = 10
READ_LEN = 100
TOTAL = N_READS * READ_LEN

# Pure ACGT cycle so BASE_PACK can losslessly round-trip.
PURE_ACGT_SEQ = (b"ACGT" * (READ_LEN // 4)) * N_READS
PHRED_CYCLE_QUAL = bytes((30 + (i % 11)) for i in range(TOTAL))
# Illumina-8 bin centres — round-trip byte-exact through QUALITY_BINNED.
_BIN_CENTRES = (0, 5, 15, 22, 27, 32, 37, 40)
QUAL_BIN_CENTRE = bytes(_BIN_CENTRES * (TOTAL // len(_BIN_CENTRES)))


def _build(*,
           sequences_codec: Compression | None,
           qualities_codec: Compression | None,
           qual_bytes: bytes = PHRED_CYCLE_QUAL) -> WrittenGenomicRun:
    overrides: dict[str, Compression] = {}
    if sequences_codec is not None:
        overrides["sequences"] = sequences_codec
    if qualities_codec is not None:
        overrides["qualities"] = qualities_codec
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_TEST",
        positions=np.arange(N_READS, dtype=np.int64) * 1000,
        mapping_qualities=np.full(N_READS, 60, dtype=np.uint8),
        flags=np.zeros(N_READS, dtype=np.uint32),
        sequences=np.frombuffer(PURE_ACGT_SEQ, dtype=np.uint8),
        qualities=np.frombuffer(qual_bytes, dtype=np.uint8),
        offsets=np.arange(N_READS, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N_READS, READ_LEN, dtype=np.uint32),
        cigars=["100M"] * N_READS,
        read_names=[f"r{i:03d}" for i in range(N_READS)],
        mate_chromosomes=["chr1"] * N_READS,
        mate_positions=np.full(N_READS, -1, dtype=np.int64),
        template_lengths=np.zeros(N_READS, dtype=np.int32),
        chromosomes=["chr1"] * N_READS,
        signal_codec_overrides=overrides,
    )


def _write(out_path: Path, run: WrittenGenomicRun, title: str) -> None:
    SpectralDataset.write_minimal(
        out_path,
        title=title,
        isa_investigation_id="ISA-M86A-10",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    print(f"wrote {out_path} ({out_path.stat().st_size} bytes)")


def main() -> None:
    here = Path(__file__).parent

    _write(
        here / "m86_codec_rans_order0.tio",
        _build(sequences_codec=Compression.RANS_ORDER0,
               qualities_codec=Compression.RANS_ORDER0),
        "m86-rans-order0-cross-lang-fixture",
    )
    _write(
        here / "m86_codec_rans_order1.tio",
        _build(sequences_codec=Compression.RANS_ORDER1,
               qualities_codec=Compression.RANS_ORDER1),
        "m86-rans-order1-cross-lang-fixture",
    )
    _write(
        here / "m86_codec_base_pack.tio",
        _build(sequences_codec=Compression.BASE_PACK,
               qualities_codec=Compression.BASE_PACK),
        "m86-base-pack-cross-lang-fixture",
    )
    # quality_binned fixture: sequences via BASE_PACK +
    # qualities via QUALITY_BINNED (per the test's @compression
    # attribute checks).
    _write(
        here / "m86_codec_quality_binned.tio",
        _build(sequences_codec=Compression.BASE_PACK,
               qualities_codec=Compression.QUALITY_BINNED,
               qual_bytes=QUAL_BIN_CENTRE),
        "m86-quality-binned-cross-lang-fixture",
    )


if __name__ == "__main__":
    main()
