"""ref_diff v2 writer/reader dispatch tests (Task #12).

Verifies:
1. Default v1.8 write produces refdiff_v2 group layout.
2. Unmapped reads fall back to BASE_PACK (v2 not eligible).
3. v2 default round-trip: sequence bytes match.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import ref_diff_v2 as rdv2
from ttio.enums import Compression

if not rdv2.HAVE_NATIVE_LIB:
    pytest.skip(
        "requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
        allow_module_level=True,
    )

N = 50
READ_LEN = 100
TOTAL_BASES = N * READ_LEN
RNG = np.random.default_rng(123)


def _build_minimal_run(**extra):
    """Build a minimal WrittenGenomicRun with N=50 fully-mapped records."""
    from ttio.written_genomic_run import WrittenGenomicRun

    positions = (np.arange(N) * 50 + 1).astype(np.int64)
    chromosomes = ["22"] * N
    cigars = [f"{READ_LEN}M"] * N

    # Build a reference long enough to cover all reads.
    # positions are 1-based; last read at positions[N-1] + READ_LEN - 1
    ref_len = int(positions[-1]) + READ_LEN + 100
    ref_bytes = bytes([ord("ACGT"[i % 4]) for i in range(ref_len)])
    reference_chrom_seqs = {"22": ref_bytes}

    # Sequences: exact copies of the reference (0% sub rate → perfectly compressible).
    sequences_parts = bytearray()
    for i in range(N):
        ref_start = int(positions[i]) - 1  # 0-based
        sequences_parts.extend(ref_bytes[ref_start:ref_start + READ_LEN])
    seq_bytes = bytes(sequences_parts)
    qual_bytes = bytes([30] * TOTAL_BASES)

    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.dispatch_test",
        platform="ILLUMINA",
        sample_name="DISP_TEST",
        positions=positions,
        mapping_qualities=np.full(N, 60, dtype=np.uint8),
        flags=np.zeros(N, dtype=np.uint32),
        sequences=np.frombuffer(seq_bytes, dtype=np.uint8),
        qualities=np.frombuffer(qual_bytes, dtype=np.uint8),
        offsets=np.arange(N, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N, READ_LEN, dtype=np.uint32),
        cigars=cigars,
        read_names=[f"r{i}" for i in range(N)],
        mate_chromosomes=["*"] * N,
        mate_positions=np.zeros(N, dtype=np.int64),
        template_lengths=np.zeros(N, dtype=np.int32),
        chromosomes=chromosomes,
        reference_chrom_seqs=reference_chrom_seqs,
        embed_reference=True,
        **extra,
    )


def _write_run(tmp_path: Path, run, fname: str = "test.tio") -> Path:
    """Write a minimal SpectralDataset with this run; return the file path."""
    from ttio.spectral_dataset import SpectralDataset

    out = tmp_path / fname
    SpectralDataset.write_minimal(
        out,
        title="dispatch_test",
        isa_investigation_id="DISP001",
        runs={},
        genomic_runs={"r0": run},
    )
    return out


# ---------------------------------------------------------------------------
# Test 1: default v1.8 write produces refdiff_v2 group layout
# ---------------------------------------------------------------------------

def test_default_writes_refdiff_v2(tmp_path: Path):
    """Default v1.8 write produces signal_channels/sequences/refdiff_v2 group."""
    run = _build_minimal_run()
    out = _write_run(tmp_path, run)

    import h5py
    with h5py.File(out, "r") as f:
        seq = f["study/genomic_runs/r0/signal_channels/sequences"]
        assert isinstance(seq, h5py.Group), (
            "v1.8 default should write sequences as a GROUP, "
            "got: " + str(type(seq))
        )
        assert "refdiff_v2" in seq, (
            "group must contain refdiff_v2 child dataset, "
            "got: " + str(list(seq.keys()))
        )
        ds = seq["refdiff_v2"]
        assert int(ds.attrs["compression"]) == int(Compression.REF_DIFF_V2), (
            f"@compression must be REF_DIFF_V2 = {int(Compression.REF_DIFF_V2)}, "
            f"got {ds.attrs['compression']}"
        )


# ---------------------------------------------------------------------------
# Test 2: unmapped reads fall back to BASE_PACK (v2 not eligible)
# ---------------------------------------------------------------------------

def test_unmapped_reads_skip_v2(tmp_path: Path):
    """Reads with cigar='*' fall back to BASE_PACK on the v1 path."""
    run = _build_minimal_run()
    cigars_list = list(run.cigars)
    cigars_list[10] = "*"
    run.cigars = cigars_list
    out = _write_run(tmp_path, run, fname="unmapped.tio")

    import h5py
    with h5py.File(out, "r") as f:
        seq = f["study/genomic_runs/r0/signal_channels/sequences"]
        assert isinstance(seq, h5py.Dataset), (
            "unmapped reads → v2 not eligible → flat Dataset expected"
        )
        assert int(seq.attrs["compression"]) == int(Compression.BASE_PACK), (
            f"unmapped run must fall back to BASE_PACK = 6, "
            f"got {seq.attrs['compression']}"
        )


# ---------------------------------------------------------------------------
# Test 3: v2 default round-trip
# ---------------------------------------------------------------------------

def test_v2_round_trip_default(tmp_path: Path):
    """Round-trip a default (v2) file: sequence bytes read back correctly."""
    from ttio.spectral_dataset import SpectralDataset

    run = _build_minimal_run()
    expected_seq = bytes(run.sequences.tobytes())
    out = _write_run(tmp_path, run, fname="v2_rt.tio")

    ds = SpectralDataset.open(out)
    try:
        grun = ds.genomic_runs["r0"]
        assert len(grun) == N
        reconstructed = bytearray()
        for i in range(N):
            record = grun[i]
            seq = record.sequence
            reconstructed.extend(seq.encode("ascii") if isinstance(seq, str) else bytes(seq))
        assert bytes(reconstructed) == expected_seq
    finally:
        ds.close()
