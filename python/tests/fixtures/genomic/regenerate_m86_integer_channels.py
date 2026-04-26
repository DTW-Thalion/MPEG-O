"""Regenerate tests/fixtures/genomic/m86_codec_integer_channels.tio.

Run from repo root:
    python python/tests/fixtures/genomic/regenerate_m86_integer_channels.py

Cross-language conformance fixture for M86 Phase B (HANDOFF.md
§6.4): a 100-read genomic run whose three integer channels
(positions, flags, mapping_qualities) are all written through the
M83 rANS codecs via the Phase B int-channel dispatch path. ObjC
and Java construct the same input from a deterministic generator
and assert byte-exact decode through their respective readers.

Other byte/string channels use the M82 baseline (no overrides on
sequences/qualities/read_names) so this fixture isolates the
integer-channel codec wiring.

Re-run only when the M86 Phase B spec changes — the committed
fixture is the contract.
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
    # Phase B integer-channel inputs (HANDOFF.md §6.4):
    #  - positions: monotonic ``i * 1000 + 1_000_000`` — ideal for
    #    rANS order-1 because the LE-byte stream of monotonically
    #    increasing int64 values is highly regular.
    #  - flags:     alternating 0x0001 / 0x0083 — paired/unpaired
    #    SAM-flag pattern; rANS order-0 captures the bimodal
    #    distribution.
    #  - mapping_qualities: 60 for 80% of reads, 0 for 20% —
    #    realistic Illumina MAPQ distribution; rANS order-1.
    positions = np.array(
        [i * 1000 + 1_000_000 for i in range(N_READS)],
        dtype=np.int64,
    )
    flags = np.array(
        [0x0001 if (i % 2 == 0) else 0x0083 for i in range(N_READS)],
        dtype=np.uint32,
    )
    mapq = np.array(
        [60 if (i % 5) != 0 else 0 for i in range(N_READS)],
        dtype=np.uint8,
    )
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_PHASEB_TEST",
        positions=positions,
        mapping_qualities=mapq,
        flags=flags,
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(N_READS, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N_READS, READ_LEN, dtype=np.uint32),
        cigars=["100M"] * N_READS,
        read_names=[f"r{i}" for i in range(N_READS)],
        mate_chromosomes=["chr1"] * N_READS,
        mate_positions=np.full(N_READS, -1, dtype=np.int64),
        template_lengths=np.zeros(N_READS, dtype=np.int32),
        chromosomes=["chr1"] * N_READS,
        signal_codec_overrides={
            "positions": Compression.RANS_ORDER1,
            "flags": Compression.RANS_ORDER0,
            "mapping_qualities": Compression.RANS_ORDER1,
        },
    )


def main() -> None:
    out = Path(__file__).parent / "m86_codec_integer_channels.tio"
    SpectralDataset.write_minimal(
        out,
        title="m86-integer-channels-cross-lang-fixture",
        isa_investigation_id="ISA-M86B-100",
        runs={},
        genomic_runs={"genomic_0001": _build()},
    )
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
