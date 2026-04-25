"""M82 GenomicRun + AlignedRead acceptance tests."""
from __future__ import annotations

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
