"""M82 GenomicRun + AlignedRead acceptance tests."""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest


def test_aligned_read_basic_fields():
    from ttio.aligned_read import AlignedRead

    read = AlignedRead(
        read_name="read_001",
        chromosome="chr1",
        position=12345,
        mapping_quality=60,
        cigar="150M",
        sequence="A" * 150,
        qualities=b"I" * 150,
        flags=0,
        mate_chromosome="",
        mate_position=-1,
        template_length=0,
    )
    assert read.read_name == "read_001"
    assert read.chromosome == "chr1"
    assert read.position == 12345
    assert read.mapping_quality == 60
    assert read.cigar == "150M"
    assert len(read.sequence) == 150
    assert len(read.qualities) == 150
    assert read.flags == 0
    assert read.mate_chromosome == ""
    assert read.mate_position == -1
    assert read.template_length == 0
    assert read.read_length == 150


def test_aligned_read_flag_accessors():
    from ttio.aligned_read import AlignedRead

    def _make(flags: int) -> AlignedRead:
        return AlignedRead(
            read_name="r", chromosome="chr1", position=0,
            mapping_quality=0, cigar="0M", sequence="", qualities=b"",
            flags=flags, mate_chromosome="", mate_position=-1,
            template_length=0,
        )

    # is_mapped: True when 0x4 unset
    assert _make(flags=0).is_mapped is True
    assert _make(flags=0x4).is_mapped is False

    # is_paired: True when 0x1 set
    assert _make(flags=0).is_paired is False
    assert _make(flags=0x1).is_paired is True

    # is_reverse: True when 0x10 set
    assert _make(flags=0).is_reverse is False
    assert _make(flags=0x10).is_reverse is True

    # is_secondary: True when 0x100 set
    assert _make(flags=0).is_secondary is False
    assert _make(flags=0x100).is_secondary is True

    # is_supplementary: True when 0x800 set
    assert _make(flags=0).is_supplementary is False
    assert _make(flags=0x800).is_supplementary is True


def test_aligned_read_is_frozen():
    """AlignedRead must be immutable (frozen dataclass)."""
    from ttio.aligned_read import AlignedRead

    read = AlignedRead(
        read_name="r", chromosome="chr1", position=0,
        mapping_quality=0, cigar="0M", sequence="", qualities=b"",
        flags=0, mate_chromosome="", mate_position=-1,
        template_length=0,
    )
    with pytest.raises((AttributeError, TypeError)):
        read.position = 999  # type: ignore[misc]


def _make_written_run(
    n_reads: int = 100,
    read_length: int = 150,
    chromosomes: list[str] | None = None,
    paired: bool = False,
) -> "WrittenGenomicRun":
    """Build a synthetic WrittenGenomicRun with realistic structure."""
    from ttio.written_genomic_run import WrittenGenomicRun

    if chromosomes is None:
        chromosomes = ["chr1", "chr2", "chrX"]
    rng = np.random.default_rng(42)

    # Round-robin chromosomes; positions ramp inside each.
    chroms = [chromosomes[i % len(chromosomes)] for i in range(n_reads)]
    positions = np.array(
        [10_000 + (i // len(chromosomes)) * 100 for i in range(n_reads)],
        dtype=np.int64,
    )
    flags = np.zeros(n_reads, dtype=np.uint32)
    if paired:
        flags |= 0x1  # paired
    mapqs = np.full(n_reads, 60, dtype=np.uint8)

    bases = b"ACGT"
    seq_concat = bytes(
        rng.choice(list(bases), size=n_reads * read_length).tolist()
    )
    qual_concat = bytes([30] * (n_reads * read_length))
    sequences = np.frombuffer(seq_concat, dtype=np.uint8)
    qualities = np.frombuffer(qual_concat, dtype=np.uint8)

    offsets = np.arange(n_reads, dtype=np.uint64) * read_length
    lengths = np.full(n_reads, read_length, dtype=np.uint32)

    cigars = [f"{read_length}M" for _ in range(n_reads)]
    read_names = [f"read_{i:06d}" for i in range(n_reads)]

    if paired:
        mate_chroms = list(chroms)  # same chrom for mate
        mate_positions = positions + 200
        template_lengths = np.full(n_reads, 200, dtype=np.int32)
    else:
        mate_chroms = ["" for _ in range(n_reads)]
        mate_positions = np.full(n_reads, -1, dtype=np.int64)
        template_lengths = np.zeros(n_reads, dtype=np.int32)

    return WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
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


def _make_index(n_reads: int = 6) -> "GenomicIndex":
    from ttio.genomic_index import GenomicIndex
    return GenomicIndex(
        offsets=np.arange(n_reads, dtype=np.uint64) * 150,
        lengths=np.full(n_reads, 150, dtype=np.uint32),
        chromosomes=["chr1", "chr1", "chr2", "chr2", "chrX", "chr1"],
        positions=np.array([100, 15000, 100, 200, 100, 25000], dtype=np.int64),
        mapping_qualities=np.array([60, 60, 0, 60, 60, 60], dtype=np.uint8),
        flags=np.array([0, 0, 0x4, 0x10, 0x1, 0], dtype=np.uint32),
    )


def test_genomic_index_count():
    idx = _make_index(6)
    assert idx.count == 6


def test_genomic_index_indices_for_region():
    idx = _make_index(6)
    # chr1, [10000, 20000): only reads with chrom == chr1 AND 10000 <= pos < 20000
    # Read 0: chr1@100 — out (pos < 10000)
    # Read 1: chr1@15000 — in
    # Read 5: chr1@25000 — out (pos >= 20000)
    result = idx.indices_for_region("chr1", 10000, 20000)
    assert result == [1]


def test_genomic_index_indices_for_region_no_matches():
    idx = _make_index(6)
    assert idx.indices_for_region("chrY", 0, 1_000_000) == []


def test_genomic_index_indices_for_unmapped():
    idx = _make_index(6)
    # Read 2 has flag 0x4 set
    assert idx.indices_for_unmapped() == [2]


def test_genomic_index_indices_for_flag():
    idx = _make_index(6)
    # Read 3 has flag 0x10 (reverse)
    assert idx.indices_for_flag(0x10) == [3]
    # Read 4 has flag 0x1 (paired)
    assert idx.indices_for_flag(0x1) == [4]


def test_written_genomic_run_construction():
    from ttio.written_genomic_run import WrittenGenomicRun

    run = WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.zeros(2, dtype=np.int64),
        mapping_qualities=np.zeros(2, dtype=np.uint8),
        flags=np.zeros(2, dtype=np.uint32),
        sequences=np.zeros(300, dtype=np.uint8),
        qualities=np.zeros(300, dtype=np.uint8),
        offsets=np.array([0, 150], dtype=np.uint64),
        lengths=np.full(2, 150, dtype=np.uint32),
        cigars=["150M", "150M"],
        read_names=["r1", "r2"],
        mate_chromosomes=["", ""],
        mate_positions=np.full(2, -1, dtype=np.int64),
        template_lengths=np.zeros(2, dtype=np.int32),
        chromosomes=["chr1", "chr1"],
    )
    assert run.acquisition_mode == 7
    assert run.reference_uri == "GRCh38.p14"
    assert len(run.cigars) == 2
    assert run.signal_compression == "gzip"  # default
    assert run.provenance_records == []      # default


def test_signal_channel_helpers_roundtrip(tmp_path: Path):
    """uint8/uint32/int64 channel helpers round-trip via HDF5."""
    from ttio._hdf5_io import (
        _write_uint8_channel,
        _write_uint32_channel,
        _write_int64_channel,
    )
    from ttio.providers.hdf5 import Hdf5Provider

    p = tmp_path / "channels.h5"
    sp = Hdf5Provider.open(str(p), mode="w")
    try:
        root = sp.root_group()
        grp = root.create_group("test")
        _write_uint8_channel(
            grp, "u8", np.array([0, 1, 254, 255], dtype=np.uint8), "gzip"
        )
        _write_uint32_channel(
            grp, "u32",
            np.array([0, 1, 2**31, 2**32 - 1], dtype=np.uint32),
            "gzip",
        )
        _write_int64_channel(
            grp, "i64",
            np.array([-(2**62), -1, 0, 2**62], dtype=np.int64),
            "gzip",
        )
    finally:
        sp.close()

    # Read back via h5py and verify exact values + dtypes
    with h5py.File(p, "r") as f:
        u8 = f["test/u8"][:]
        u32 = f["test/u32"][:]
        i64 = f["test/i64"][:]
    assert u8.dtype == np.uint8
    assert list(u8) == [0, 1, 254, 255]
    assert u32.dtype == np.uint32
    assert list(u32) == [0, 1, 2**31, 2**32 - 1]
    assert i64.dtype == np.int64
    assert list(i64) == [-(2**62), -1, 0, 2**62]


def test_m82_public_exports():
    """The four new public types must be importable from `ttio`."""
    import ttio
    assert hasattr(ttio, "AlignedRead")
    assert hasattr(ttio, "GenomicIndex")
    assert hasattr(ttio, "GenomicRun")
    assert hasattr(ttio, "WrittenGenomicRun")
    # __all__ membership
    assert "AlignedRead" in ttio.__all__
    assert "GenomicIndex" in ttio.__all__
    assert "GenomicRun" in ttio.__all__
    assert "WrittenGenomicRun" in ttio.__all__


def test_genomic_index_disk_roundtrip(tmp_path: Path):
    """GenomicIndex.write → .read returns equal columns."""
    from ttio.genomic_index import GenomicIndex
    from ttio.providers.hdf5 import Hdf5Provider

    original = _make_index(6)

    p = tmp_path / "index.h5"
    sp = Hdf5Provider.open(str(p), mode="w")
    try:
        root = sp.root_group()
        grp = root.create_group("genomic_index")
        original.write(grp)
    finally:
        sp.close()

    sp = Hdf5Provider.open(str(p), mode="r")
    try:
        root = sp.root_group()
        grp = root.open_group("genomic_index")
        loaded = GenomicIndex.read(grp)
    finally:
        sp.close()

    assert loaded.count == original.count
    np.testing.assert_array_equal(loaded.offsets, original.offsets)
    np.testing.assert_array_equal(loaded.lengths, original.lengths)
    np.testing.assert_array_equal(loaded.positions, original.positions)
    np.testing.assert_array_equal(
        loaded.mapping_qualities, original.mapping_qualities
    )
    np.testing.assert_array_equal(loaded.flags, original.flags)
    assert loaded.chromosomes == original.chromosomes


def test_write_minimal_creates_genomic_runs_group(tmp_path: Path):
    """write_minimal with genomic_runs creates the expected HDF5 layout."""
    from ttio.spectral_dataset import SpectralDataset

    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p,
        title="m82-smoke",
        isa_investigation_id="ISA-001",
        runs={},
        genomic_runs={"genomic_0001": _make_written_run(n_reads=10)},
    )

    with h5py.File(p, "r") as f:
        assert "study/genomic_runs" in f
        assert "study/genomic_runs/genomic_0001" in f
        run = f["study/genomic_runs/genomic_0001"]
        # Run-level attributes
        assert int(run.attrs["acquisition_mode"]) == 7
        assert run.attrs["modality"].decode("utf-8") == "genomic_sequencing"
        assert int(run.attrs["spectrum_class"]) == 5
        assert run.attrs["reference_uri"].decode("utf-8") == "GRCh38.p14"
        assert run.attrs["platform"].decode("utf-8") == "ILLUMINA"
        assert run.attrs["sample_name"].decode("utf-8") == "NA12878"
        assert int(run.attrs["read_count"]) == 10
        # Sub-groups
        assert "genomic_index" in run
        assert "signal_channels" in run
        # Index columns
        assert "offsets" in run["genomic_index"]
        assert "chromosomes" in run["genomic_index"]
        # Signal channels
        assert "sequences" in run["signal_channels"]
        assert "qualities" in run["signal_channels"]
        assert "cigars" in run["signal_channels"]
        assert "read_names" in run["signal_channels"]
        assert "mate_info" in run["signal_channels"]
        assert "positions" in run["signal_channels"]
        assert "flags" in run["signal_channels"]
        assert "mapping_qualities" in run["signal_channels"]
        # _run_names CSV attribute
        names = f["study/genomic_runs"].attrs["_run_names"].decode("utf-8")
        assert names == "genomic_0001"


def test_write_minimal_genomic_sets_format_version_and_flag(tmp_path: Path):
    """opt_genomic flag added; format_version bumps to 1.4 when genomic runs present."""
    import json
    from ttio.spectral_dataset import SpectralDataset

    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p,
        title="t",
        isa_investigation_id="i",
        runs={},
        genomic_runs={"genomic_0001": _make_written_run(n_reads=5)},
    )

    # Read feature flags + format version via raw h5py.
    # write_feature_flags stores: root attr "ttio_format_version" (string)
    # and root attr "ttio_features" (JSON-encoded list of strings).
    with h5py.File(p, "r") as f:
        format_version = f.attrs["ttio_format_version"]
        # The attribute is a fixed-length bytes value; decode if needed.
        if isinstance(format_version, bytes):
            format_version = format_version.decode("utf-8")
        features_raw = f.attrs["ttio_features"]
        if isinstance(features_raw, bytes):
            features_raw = features_raw.decode("utf-8")
        feature_list = json.loads(features_raw)

    assert format_version == "1.4"
    assert "opt_genomic" in feature_list


def test_spectral_dataset_genomic_runs_property(tmp_path: Path):
    """SpectralDataset.open exposes genomic_runs dict."""
    from ttio.spectral_dataset import SpectralDataset

    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p,
        title="t",
        isa_investigation_id="i",
        runs={},
        genomic_runs={
            "genomic_0001": _make_written_run(n_reads=10),
            "genomic_0002": _make_written_run(n_reads=5),
        },
    )

    ds = SpectralDataset.open(p)
    try:
        assert set(ds.genomic_runs.keys()) == {"genomic_0001", "genomic_0002"}
        # We don't materialise reads yet — Task 9 — but the GenomicRun
        # objects must exist with the right names.
        assert ds.genomic_runs["genomic_0001"].name == "genomic_0001"
        assert ds.genomic_runs["genomic_0002"].name == "genomic_0002"
    finally:
        ds.close()


def test_spectral_dataset_no_genomic_runs_pre_m82_compat(tmp_path: Path):
    """Files without /study/genomic_runs/ → empty dict, no error."""
    from ttio.spectral_dataset import SpectralDataset

    p = tmp_path / "ms_only.tio"
    # Write a normal MS-only file with no genomic_runs= argument.
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i", runs={}
    )
    ds = SpectralDataset.open(p)
    try:
        assert ds.genomic_runs == {}
    finally:
        ds.close()


def test_basic_roundtrip_100_reads(tmp_path: Path):
    """Acceptance #1: 100-read GenomicRun round-trips with all fields."""
    from ttio.spectral_dataset import SpectralDataset

    written = _make_written_run(n_reads=100, paired=False)

    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": written},
    )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == 100

        for i in (0, 50, 99):
            read = gr[i]
            # Read-name from synthetic helper
            assert read.read_name == f"read_{i:06d}"
            # Position
            assert read.position == int(written.positions[i])
            # Chromosome
            assert read.chromosome == written.chromosomes[i]
            # Cigar
            assert read.cigar == written.cigars[i]
            # Sequence — bytes round-trip via ASCII
            expected_seq = bytes(
                written.sequences[
                    int(written.offsets[i]):
                    int(written.offsets[i]) + int(written.lengths[i])
                ]
            ).decode("ascii")
            assert read.sequence == expected_seq
            # Qualities
            expected_q = bytes(
                written.qualities[
                    int(written.offsets[i]):
                    int(written.offsets[i]) + int(written.lengths[i])
                ]
            )
            assert read.qualities == expected_q
            # Mapping quality
            assert read.mapping_quality == int(written.mapping_qualities[i])
            # Flags
            assert read.flags == int(written.flags[i])
            # Mate (unpaired in this test)
            assert read.mate_chromosome == ""
            assert read.mate_position == -1
            assert read.template_length == 0
    finally:
        ds.close()


def test_region_query(tmp_path: Path):
    """Acceptance #2: reads_in_region returns only matching reads."""
    from ttio.spectral_dataset import SpectralDataset

    written = _make_written_run(n_reads=100, paired=False)
    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": written},
    )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        # Synthetic helper assigns chromosomes round-robin and ramps
        # positions per chromosome by 100. Pick a window that should
        # capture some chr1 reads but not chr2 or chrX.
        results = gr.reads_in_region("chr1", 10_000, 10_500)
        assert len(results) > 0
        for r in results:
            assert r.chromosome == "chr1"
            assert 10_000 <= r.position < 10_500
        # Empty window
        assert gr.reads_in_region("chrY", 0, 1_000_000) == []
    finally:
        ds.close()


def test_flag_filter(tmp_path: Path):
    """Acceptance #3: indices_for_unmapped + indices_for_flag work end-to-end."""
    from ttio.spectral_dataset import SpectralDataset

    written = _make_written_run(n_reads=100, paired=False)
    # Patch a few flags: read 7 unmapped, reads 3 and 9 reverse-strand.
    written.flags[7] |= 0x4
    written.flags[3] |= 0x10
    written.flags[9] |= 0x10

    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": written},
    )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        unmapped = gr.index.indices_for_unmapped()
        assert unmapped == [7]
        reverse = gr.index.indices_for_flag(0x10)
        assert sorted(reverse) == [3, 9]
    finally:
        ds.close()


def test_paired_end_mate_info(tmp_path: Path):
    """Acceptance #4: mate_chromosome / mate_position / template_length round-trip."""
    from ttio.spectral_dataset import SpectralDataset

    written = _make_written_run(n_reads=100, paired=True)

    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": written},
    )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        read = gr[0]
        assert read.is_paired is True
        assert read.mate_chromosome == written.mate_chromosomes[0]
        assert read.mate_position == int(written.mate_positions[0])
        assert read.template_length == int(written.template_lengths[0])
    finally:
        ds.close()


def test_large_run_10k_reads(tmp_path: Path):
    """Acceptance #5: 10K-read run iterates and spot-checks correctly."""
    from ttio.spectral_dataset import SpectralDataset

    written = _make_written_run(n_reads=10_000, paired=False)
    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": written},
    )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == 10_000
        for i in (0, 5_000, 9_999):
            read = gr[i]
            assert read.read_name == f"read_{i:06d}"
            assert read.position == int(written.positions[i])
    finally:
        ds.close()


def test_empty_run(tmp_path: Path):
    """Acceptance #6: 0-read GenomicRun round-trips."""
    from ttio.spectral_dataset import SpectralDataset
    from ttio.written_genomic_run import WrittenGenomicRun

    empty = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.zeros(0, dtype=np.int64),
        mapping_qualities=np.zeros(0, dtype=np.uint8),
        flags=np.zeros(0, dtype=np.uint32),
        sequences=np.zeros(0, dtype=np.uint8),
        qualities=np.zeros(0, dtype=np.uint8),
        offsets=np.zeros(0, dtype=np.uint64),
        lengths=np.zeros(0, dtype=np.uint32),
        cigars=[],
        read_names=[],
        mate_chromosomes=[],
        mate_positions=np.zeros(0, dtype=np.int64),
        template_lengths=np.zeros(0, dtype=np.int32),
        chromosomes=[],
    )

    p = tmp_path / "g.tio"
    SpectralDataset.write_minimal(
        p, title="t", isa_investigation_id="i",
        runs={}, genomic_runs={"genomic_0001": empty},
    )

    ds = SpectralDataset.open(p)
    try:
        gr = ds.genomic_runs["genomic_0001"]
        assert len(gr) == 0
        assert list(gr) == []
        assert gr.reads_in_region("chr1", 0, 1_000_000_000) == []
    finally:
        ds.close()
