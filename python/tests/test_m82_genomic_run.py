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
