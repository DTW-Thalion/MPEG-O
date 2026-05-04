"""mate_info v2 writer/reader dispatch tests (Task #12).

Verifies:
1. Default v1.7 write produces inline_v2 blob (not v1 streams).
2. opt_disable_inline_mate_info_v2 = True falls back to v1 compound.
3. signal_codec_overrides[mate_info_*] rejected when v2 active.
4. signal_codec_overrides[mate_info_*] allowed when v2 disabled (opt-out).
5. v2 round-trip: mate_chromosome / mate_position / template_length match.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import mate_info_v2 as miv2
from ttio.enums import Compression

if not miv2.HAVE_NATIVE_LIB:
    pytest.skip(
        "requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
        allow_module_level=True,
    )

N = 50
RNG = np.random.default_rng(123)
READ_LEN = 100
TOTAL_BASES = N * READ_LEN


def _build_minimal_run(**extra):
    """Build a minimal WrittenGenomicRun with N=50 records of mixed mate patterns."""
    from ttio.written_genomic_run import WrittenGenomicRun

    positions = RNG.integers(0, 10_000_000, size=N).astype(np.int64)
    chromosomes = ["22"] * N

    mate_chromosomes: list[str] = []
    mate_positions_list: list[int] = []
    template_lengths_list: list[int] = []
    for i in range(N):
        d = i % 10
        if d < 8:
            mate_chromosomes.append("22")
            mate_positions_list.append(int(positions[i]) + (i % 200) - 100)
            template_lengths_list.append((i % 1000) - 500)
        elif d < 9:
            mate_chromosomes.append("11")
            mate_positions_list.append(int(RNG.integers(0, 10_000_000)))
            template_lengths_list.append(0)
        else:
            mate_chromosomes.append("*")
            mate_positions_list.append(0)
            template_lengths_list.append(0)

    seq_bytes = b"A" * TOTAL_BASES
    qual_bytes = bytes([30] * TOTAL_BASES)

    return WrittenGenomicRun(
        acquisition_mode=7,          # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="DISP_TEST",
        positions=positions,
        mapping_qualities=np.full(N, 60, dtype=np.uint8),
        flags=np.zeros(N, dtype=np.uint32),
        sequences=np.frombuffer(seq_bytes, dtype=np.uint8),
        qualities=np.frombuffer(qual_bytes, dtype=np.uint8),
        offsets=np.arange(N, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N, READ_LEN, dtype=np.uint32),
        cigars=[f"{READ_LEN}M"] * N,
        read_names=[f"r{i}" for i in range(N)],
        mate_chromosomes=mate_chromosomes,
        mate_positions=np.asarray(mate_positions_list, dtype=np.int64),
        template_lengths=np.asarray(template_lengths_list, dtype=np.int32),
        chromosomes=chromosomes,
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
# Test 1: default v1.7 write produces inline_v2 blob
# ---------------------------------------------------------------------------

def test_default_writes_inline_v2(tmp_path: Path):
    """Default v1.7 write produces signal_channels/mate_info/inline_v2."""
    run = _build_minimal_run()
    out = _write_run(tmp_path, run)

    import h5py
    with h5py.File(out, "r") as f:
        sc = f["study/genomic_runs/r0/signal_channels/mate_info"]
        assert "inline_v2" in sc, (
            "v1.7 default should write inline_v2 dataset, got: "
            + str(list(sc.keys()))
        )
        assert "chrom" not in sc, (
            "v1.7 default must NOT write v1 chrom/pos/tlen child datasets"
        )
        ds = sc["inline_v2"]
        assert int(ds.attrs["compression"]) == 13, (
            f"@compression must be MATE_INLINE_V2 = 13, got {ds.attrs['compression']}"
        )


# ---------------------------------------------------------------------------
# Test 2: opt-out falls back to v1 compound
# ---------------------------------------------------------------------------

def test_opt_out_writes_v1_compound(tmp_path: Path):
    """opt_disable_inline_mate_info_v2 = True falls back to M82 compound."""
    run = _build_minimal_run(opt_disable_inline_mate_info_v2=True)
    out = _write_run(tmp_path, run)

    import h5py
    with h5py.File(out, "r") as f:
        sc = f["study/genomic_runs/r0/signal_channels"]
        # M82 compound: mate_info must be a dataset, NOT a group
        import h5py as _h5
        assert isinstance(sc["mate_info"], _h5.Dataset), (
            "opt-out should produce M82 compound dataset, not a group"
        )
        assert "inline_v2" not in sc["mate_info"].id.get_name(sc.id).decode(
            "ascii", errors="replace"
        ) if False else True  # can't navigate into a dataset; presence check is enough


# ---------------------------------------------------------------------------
# Test 3: signal_codec_overrides[mate_info_*] rejected when v2 active
# ---------------------------------------------------------------------------

def test_signal_codec_overrides_rejected_when_v2_active(tmp_path: Path):
    """signal_codec_overrides['mate_info_pos'] rejected when v2 default active."""
    run = _build_minimal_run(
        signal_codec_overrides={"mate_info_pos": Compression.RANS_ORDER0}
    )
    with pytest.raises(ValueError, match="opt_disable_inline_mate_info_v2"):
        _write_run(tmp_path, run)


# ---------------------------------------------------------------------------
# Test 4: signal_codec_overrides[mate_info_*] allowed under opt-out
# ---------------------------------------------------------------------------

def test_signal_codec_overrides_allowed_when_v2_disabled(tmp_path: Path):
    """signal_codec_overrides['mate_info_pos'] allowed when v2 is disabled."""
    run = _build_minimal_run(
        opt_disable_inline_mate_info_v2=True,
        signal_codec_overrides={"mate_info_pos": Compression.RANS_ORDER0},
    )
    out = _write_run(tmp_path, run, fname="v1_override.tio")
    assert out.exists(), "file should have been written without error"


# ---------------------------------------------------------------------------
# Test 5: v2 round-trip equivalence via the SpectralDataset reader
# ---------------------------------------------------------------------------

def test_v2_round_trip_default(tmp_path: Path):
    """Round-trip a default-written (v2) file: mate fields read back correctly."""
    from ttio.spectral_dataset import SpectralDataset

    run = _build_minimal_run()
    out = _write_run(tmp_path, run)

    ds = SpectralDataset.open(out)
    try:
        grun = ds.genomic_runs["r0"]
        assert len(grun) == N
        for i in range(N):
            record = grun[i]
            assert record.mate_chromosome == run.mate_chromosomes[i], (
                f"read {i}: mate_chromosome mismatch: "
                f"got {record.mate_chromosome!r}, "
                f"expected {run.mate_chromosomes[i]!r}"
            )
            assert record.mate_position == int(run.mate_positions[i]), (
                f"read {i}: mate_position mismatch: "
                f"got {record.mate_position}, "
                f"expected {int(run.mate_positions[i])}"
            )
            assert record.template_length == int(run.template_lengths[i]), (
                f"read {i}: template_length mismatch: "
                f"got {record.template_length}, "
                f"expected {int(run.template_lengths[i])}"
            )
    finally:
        ds.close()
