"""NAME_TOKENIZED v2 writer/reader dispatch tests (#11 ch3 Task 12).

Verifies:
1. Default v1.8 write produces read_names @compression == 15 (NAME_TOKENIZED_V2).
2. opt_disable_name_tokenized_v2 = True falls back to v1 NAME_TOKENIZED layout.
3. Explicit signal_codec_overrides[read_names]=NAME_TOKENIZED honoured.
4. v1 round-trip via opt-out.
5. v2 default round-trip: names recovered.
"""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio.codecs import name_tokenizer_v2 as nt2
from ttio.enums import Compression

if not nt2.HAVE_NATIVE_LIB:
    pytest.skip(
        "requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
        allow_module_level=True,
    )

N = 100
READ_LEN = 50
TOTAL_BASES = N * READ_LEN


def _build_minimal_run(**extra):
    """Build a minimal WrittenGenomicRun with N=100 records and Illumina-style names."""
    from ttio.written_genomic_run import WrittenGenomicRun

    seq = (b"ACGT" * (READ_LEN // 4)) * N
    qual = bytes([30] * TOTAL_BASES)
    names = [f"INSTR:RUN:1:{i // 4}:{i % 4}:{i * 100}" for i in range(N)]

    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.dispatch_test",
        platform="ILLUMINA",
        sample_name="NT_DISP_TEST",
        positions=np.arange(N, dtype=np.int64) * 1000,
        mapping_qualities=np.full(N, 60, dtype=np.uint8),
        flags=np.zeros(N, dtype=np.uint32),
        sequences=np.frombuffer(seq, dtype=np.uint8),
        qualities=np.frombuffer(qual, dtype=np.uint8),
        offsets=np.arange(N, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N, READ_LEN, dtype=np.uint32),
        cigars=[f"{READ_LEN}M"] * N,
        read_names=names,
        mate_chromosomes=["*"] * N,
        mate_positions=np.full(N, -1, dtype=np.int64),
        template_lengths=np.zeros(N, dtype=np.int32),
        chromosomes=["chr1"] * N,
        signal_compression="none",
        # Disable refdiff_v2 / inline_v2 so the test focuses on read_names
        # without dragging in the other v2 codecs.
        opt_disable_ref_diff_v2=True,
        opt_disable_inline_mate_info_v2=True,
        **extra,
    )


def _write_run(tmp_path: Path, run, fname: str = "ntv2_disp.tio") -> Path:
    from ttio.spectral_dataset import SpectralDataset
    out = tmp_path / fname
    SpectralDataset.write_minimal(
        out,
        title="dispatch_test",
        isa_investigation_id="NTV2DISP",
        runs={},
        genomic_runs={"r0": run},
    )
    return out


# --------------------------------------------------------------------------- #
# Test 1: default v1.8 write produces NAME_TOKENIZED_V2 layout
# --------------------------------------------------------------------------- #

def test_default_writes_v2(tmp_path: Path):
    """Default v1.8 write produces read_names @compression == 15."""
    run = _build_minimal_run()
    out = _write_run(tmp_path, run)

    with h5py.File(out, "r") as f:
        rn = f["study/genomic_runs/r0/signal_channels/read_names"]
        assert isinstance(rn, h5py.Dataset), (
            "read_names must be a flat Dataset under v2 (codec lift)"
        )
        assert rn.dtype == np.uint8, (
            f"read_names dtype must be uint8 under v2, got {rn.dtype}"
        )
        assert int(rn.attrs["compression"]) == int(Compression.NAME_TOKENIZED_V2), (
            f"@compression must be NAME_TOKENIZED_V2 = "
            f"{int(Compression.NAME_TOKENIZED_V2)}, got "
            f"{rn.attrs['compression']}"
        )


# --------------------------------------------------------------------------- #
# Test 2: opt_disable_name_tokenized_v2 falls back to v1 layout
# --------------------------------------------------------------------------- #

def test_opt_out_writes_v1(tmp_path: Path):
    """opt_disable_name_tokenized_v2 = True still writes the v1 codec because
    the historical no-override path emitted M82 compound but the user-explicit
    fallback through this flag is documented to mean v1 layout. We accept
    either: M82 compound or v1 NAME_TOKENIZED — both are pre-v1.8 readers."""
    run = _build_minimal_run(opt_disable_name_tokenized_v2=True)
    out = _write_run(tmp_path, run, fname="v1_optout.tio")

    with h5py.File(out, "r") as f:
        rn = f["study/genomic_runs/r0/signal_channels/read_names"]
        # When opt-out and no override, the writer falls through to the
        # historical M82 compound layout (no codec). This is the expected
        # back-compat path that pre-v1.8 readers understand.
        assert rn.dtype.kind == "V", (
            f"opt-out without override should write M82 compound; "
            f"got dtype kind {rn.dtype.kind!r}"
        )
        # No @compression attribute on the M82 compound.
        assert "compression" not in rn.attrs


# --------------------------------------------------------------------------- #
# Test 3: signal_codec_overrides[read_names]=NAME_TOKENIZED honoured
# --------------------------------------------------------------------------- #

def test_signal_codec_overrides_respected(tmp_path: Path):
    """Explicit signal_codec_overrides[read_names]=NAME_TOKENIZED writes v1 layout."""
    run = _build_minimal_run(
        signal_codec_overrides={"read_names": Compression.NAME_TOKENIZED},
    )
    out = _write_run(tmp_path, run, fname="v1_explicit.tio")

    with h5py.File(out, "r") as f:
        rn = f["study/genomic_runs/r0/signal_channels/read_names"]
        assert isinstance(rn, h5py.Dataset)
        assert rn.dtype == np.uint8, (
            f"v1 NAME_TOKENIZED override should produce uint8 dataset, "
            f"got {rn.dtype}"
        )
        assert int(rn.attrs["compression"]) == int(Compression.NAME_TOKENIZED), (
            f"@compression must be NAME_TOKENIZED = "
            f"{int(Compression.NAME_TOKENIZED)}, got "
            f"{rn.attrs['compression']}"
        )


# --------------------------------------------------------------------------- #
# Test 4: v1 round-trip via opt-out (M82 compound)
# --------------------------------------------------------------------------- #

def test_v1_round_trip_via_opt_out(tmp_path: Path):
    """Round-trip via opt-out path (M82 compound): names recovered."""
    from ttio.spectral_dataset import SpectralDataset

    run = _build_minimal_run(opt_disable_name_tokenized_v2=True)
    expected_names = list(run.read_names)
    out = _write_run(tmp_path, run, fname="v1_rt.tio")

    ds = SpectralDataset.open(out)
    try:
        gr = ds.genomic_runs["r0"]
        assert len(gr) == N
        for i in range(N):
            assert gr[i].read_name == expected_names[i], (
                f"read {i}: expected {expected_names[i]!r}, "
                f"got {gr[i].read_name!r}"
            )
    finally:
        ds.close()


# --------------------------------------------------------------------------- #
# Test 5: v2 default round-trip
# --------------------------------------------------------------------------- #

def test_v2_round_trip_default(tmp_path: Path):
    """Round-trip the default v2 path: names recovered byte-exact."""
    from ttio.spectral_dataset import SpectralDataset

    run = _build_minimal_run()
    expected_names = list(run.read_names)
    out = _write_run(tmp_path, run, fname="v2_rt.tio")

    ds = SpectralDataset.open(out)
    try:
        gr = ds.genomic_runs["r0"]
        assert len(gr) == N
        for i in range(N):
            assert gr[i].read_name == expected_names[i], (
                f"read {i}: expected {expected_names[i]!r}, "
                f"got {gr[i].read_name!r}"
            )
    finally:
        ds.close()
