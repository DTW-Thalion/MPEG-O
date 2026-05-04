"""Round-trip smoke tests for the Phase 0 prototype."""
from __future__ import annotations

import pytest

from .encode import encode
from .decode import decode


def test_empty():
    assert decode(encode([])) == []


def test_single():
    names = ["EAS220_R1:8:1:0:1234"]
    assert decode(encode(names)) == names


def test_paired_dup():
    names = ["EAS220_R1:8:1:0:1234", "EAS220_R1:8:1:0:1234"]
    assert decode(encode(names)) == names


def test_match_k():
    names = [
        "EAS220_R1:8:1:0:1234",
        "EAS220_R1:8:1:0:1235",
        "EAS220_R1:8:1:0:1236",
    ]
    assert decode(encode(names)) == names


def test_columnar_batch():
    names = [f"EAS220_R1:8:1:0:{1000+i}" for i in range(50)]
    assert decode(encode(names)) == names


def test_mixed_shapes():
    names = [
        "EAS220_R1:8:1:0:1234",
        "weirdname",
        "EAS220_R1:8:1:0:1235",
    ]
    assert decode(encode(names)) == names


def test_two_blocks():
    names = [f"R:1:{i}" for i in range(4097)]
    assert decode(encode(names)) == names


def test_paired_alternating():
    """Common Illumina pattern: each name appears twice (R1+R2 share QNAME)."""
    base = [f"INSTR:1:101:{i*100}:{i*200}" for i in range(100)]
    names: list[str] = []
    for n in base:
        names.append(n)
        names.append(n)
    assert decode(encode(names)) == names


def test_with_pacbio_style():
    """ZMW-style names with movie/zmw/start_end."""
    names = [
        "m54006_180123_120000/zmw1/0_15000",
        "m54006_180123_120000/zmw1/15001_30000",
        "m54006_180123_120000/zmw2/0_18000",
    ]
    assert decode(encode(names)) == names
