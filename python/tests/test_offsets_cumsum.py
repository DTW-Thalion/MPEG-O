"""v1.10 #10 — offsets-cumsum dedicated tests.

Covers the helpers and the writer/reader dispatch added when the
redundant `genomic_index/offsets`, `spectrum_index/offsets`, and
`chromatogram_index/offsets` columns were dropped. `offsets[i]` is
mathematically `sum(lengths[0..i])`; readers synthesize from
`cumsum(lengths)` using a uint64 accumulator that's overflow-safe on
>4 GB genomic runs even when stored lengths are uint32.
"""
from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio.genomic_index import (
    GenomicIndex,
    _offsets_from_lengths,
    _read_offsets_or_cumsum,
)


# ── helpers ───────────────────────────────────────────────────────────────


def _make_genomic_run(n_reads: int = 10):
    """Synthetic WrittenGenomicRun with paired-style mate metadata."""
    from ttio.enums import AcquisitionMode
    from ttio.written_genomic_run import WrittenGenomicRun

    read_length = 50
    chroms = ["chr1"] * n_reads
    positions = np.arange(n_reads, dtype=np.int64) * 100
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapqs = np.full(n_reads, 60, dtype=np.uint8)
    sequences = np.tile(np.frombuffer(b"ACGT", dtype=np.uint8),
                        n_reads * read_length // 4)
    qualities = np.full(n_reads * read_length, 30, dtype=np.uint8)
    offsets = np.arange(n_reads, dtype=np.uint64) * read_length
    lengths = np.full(n_reads, read_length, dtype=np.uint32)
    cigars = [f"{read_length}M"] * n_reads
    read_names = [f"r{i:04d}" for i in range(n_reads)]
    mate_chroms = ["*"] * n_reads
    mate_positions = np.full(n_reads, -1, dtype=np.int64)
    template_lengths = np.zeros(n_reads, dtype=np.int32)
    return WrittenGenomicRun(
        acquisition_mode=AcquisitionMode.GENOMIC_WGS,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=mapqs,
        flags=flags,
        sequences=sequences,
        qualities=qualities,
        offsets=offsets,
        lengths=lengths,
        cigars=cigars,
        read_names=read_names,
        mate_chromosomes=mate_chroms,
        mate_positions=mate_positions,
        template_lengths=template_lengths,
        chromosomes=chroms,
    )


# ── _offsets_from_lengths helper ──────────────────────────────────────────


def test_offsets_from_lengths_empty():
    out = _offsets_from_lengths(np.empty(0, dtype=np.uint32))
    assert out.shape == (0,)
    assert out.dtype == np.uint64


def test_offsets_from_lengths_single():
    out = _offsets_from_lengths(np.array([100], dtype=np.uint32))
    assert out.tolist() == [0]
    assert out.dtype == np.uint64


def test_offsets_from_lengths_typical():
    lengths = np.array([100, 50, 75, 100, 25], dtype=np.uint32)
    out = _offsets_from_lengths(lengths)
    assert out.tolist() == [0, 100, 150, 225, 325]
    assert out.dtype == np.uint64


def test_offsets_from_lengths_uniform():
    lengths = np.full(20, 150, dtype=np.uint32)
    out = _offsets_from_lengths(lengths)
    expected = np.arange(20, dtype=np.uint64) * 150
    np.testing.assert_array_equal(out, expected)


def test_offsets_from_lengths_overflow_safe_uint32_to_uint64():
    """The whole point of v1.10: per-record uint32 lengths must be
    accumulated as uint64 so a >4 GB run doesn't silently wrap."""
    # 3 reads × 2^31 bytes each = 6 GB total — uint32 cumsum would
    # overflow into the 4th GB; uint64 keeps growing.
    lengths = np.array([2**31, 2**31, 2**31], dtype=np.uint32)
    out = _offsets_from_lengths(lengths)
    assert out.dtype == np.uint64
    assert out[0] == 0
    assert out[1] == 2**31
    assert out[2] == 2**32  # would be 0 with uint32 wrap
    # And the next implied "end of last record" would be 3 * 2**31:
    total = int(out[-1]) + int(lengths[-1])
    assert total == 3 * (2**31), f"expected 3*2^31, got {total}"


# ── _read_offsets_or_cumsum helper (provider integration) ─────────────────


def test_read_offsets_or_cumsum_present_uses_disk(tmp_path):
    """Pre-v1.10 file with offsets-on-disk: helper reads them directly."""
    from ttio.providers.hdf5 import Hdf5Provider
    path = tmp_path / "with_offsets.h5"
    with Hdf5Provider.open(str(path), mode="w") as p:
        idx = p.root_group().create_group("genomic_index")
        # Hand-write offsets that don't equal cumsum to prove the read
        # path uses what's on disk, not the synthesized values.
        offsets = idx.create_dataset(
            "offsets",
            from_str := __import__("ttio.enums", fromlist=["Precision"]).Precision.UINT64,
            length=4,
        )
        offsets.write(np.array([0, 999, 999, 999], dtype=np.uint64))
        lengths = idx.create_dataset("lengths", from_str.__class__.UINT32 if False
                                     else __import__("ttio.enums",
                                                     fromlist=["Precision"]).Precision.UINT32,
                                     length=4)
        lengths.write(np.array([100, 100, 100, 100], dtype=np.uint32))

    with Hdf5Provider.open(str(path), mode="r") as p:
        idx = p.root_group().open_group("genomic_index")
        out = _read_offsets_or_cumsum(idx)
    # Bogus disk values returned verbatim — proves we read disk, not cumsum
    assert out.tolist() == [0, 999, 999, 999]


def test_read_offsets_or_cumsum_absent_synthesizes(tmp_path):
    """v1.10+ file without offsets-on-disk: helper computes cumsum."""
    from ttio.providers.hdf5 import Hdf5Provider
    from ttio.enums import Precision
    path = tmp_path / "no_offsets.h5"
    with Hdf5Provider.open(str(path), mode="w") as p:
        idx = p.root_group().create_group("genomic_index")
        lengths = idx.create_dataset("lengths", Precision.UINT32, length=4)
        lengths.write(np.array([100, 50, 75, 100], dtype=np.uint32))

    with Hdf5Provider.open(str(path), mode="r") as p:
        idx = p.root_group().open_group("genomic_index")
        out = _read_offsets_or_cumsum(idx)
    assert out.tolist() == [0, 100, 150, 225]
    assert out.dtype == np.uint64


# ── End-to-end: WrittenGenomicRun.opt_keep_offsets_columns dispatch ──────


def test_default_writer_omits_offsets(tmp_path):
    """v1.10 default — offsets dataset must not appear on disk."""
    from ttio import SpectralDataset
    out = tmp_path / "default.tio"
    SpectralDataset.write_minimal(
        path=str(out), title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"chr1": _make_genomic_run()},
    )
    with h5py.File(out, "r") as f:
        idx = f["study/genomic_runs/chr1/genomic_index"]
        assert "offsets" not in idx
        assert "lengths" in idx


def test_opt_keep_offsets_writer_writes_offsets(tmp_path):
    """opt_keep_offsets_columns=True: backward-compat path keeps it."""
    from ttio import SpectralDataset
    run = replace(_make_genomic_run(), opt_keep_offsets_columns=True)
    out = tmp_path / "keep.tio"
    SpectralDataset.write_minimal(
        path=str(out), title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"chr1": run},
    )
    with h5py.File(out, "r") as f:
        idx = f["study/genomic_runs/chr1/genomic_index"]
        assert "offsets" in idx
        assert "lengths" in idx
        # Disk offsets must equal cumsum(lengths).
        offsets = idx["offsets"][:]
        lengths = idx["lengths"][:]
        expected = _offsets_from_lengths(lengths.astype(np.uint32))
        np.testing.assert_array_equal(offsets, expected)


def test_default_writer_round_trip_via_genomic_index_read(tmp_path):
    """Read-back must produce GenomicIndex with correct offsets."""
    from ttio import SpectralDataset
    out = tmp_path / "rt.tio"
    src_run = _make_genomic_run(n_reads=20)
    SpectralDataset.write_minimal(
        path=str(out), title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"chr1": src_run},
    )
    with SpectralDataset.open(str(out)) as ds:
        gr = ds.genomic_runs["chr1"]
        # genomic_index attached to the run loads eagerly.
        idx = gr.index  # cached GenomicIndex per genomic_run.py
        np.testing.assert_array_equal(idx.lengths, src_run.lengths)
        np.testing.assert_array_equal(idx.offsets, src_run.offsets)
        # And those offsets must match the cumsum invariant.
        np.testing.assert_array_equal(
            idx.offsets, _offsets_from_lengths(idx.lengths))


def test_opt_keep_offsets_round_trip_byte_identical_results(tmp_path):
    """Both writer paths must produce GenomicIndex.read identical
    `offsets` values — the only on-disk difference is the column's
    presence vs absence. This protects against a synthesizer/disk
    drift bug."""
    from ttio import SpectralDataset
    src = _make_genomic_run(n_reads=15)
    src_keep = replace(src, opt_keep_offsets_columns=True)

    p_default = tmp_path / "default.tio"
    p_keep = tmp_path / "keep.tio"
    SpectralDataset.write_minimal(
        path=str(p_default), title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"chr1": src},
    )
    SpectralDataset.write_minimal(
        path=str(p_keep), title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"chr1": src_keep},
    )

    with SpectralDataset.open(str(p_default)) as ds_d, \
         SpectralDataset.open(str(p_keep)) as ds_k:
        offs_default = ds_d.genomic_runs["chr1"].index.offsets
        offs_keep = ds_k.genomic_runs["chr1"].index.offsets
        np.testing.assert_array_equal(offs_default, offs_keep)
