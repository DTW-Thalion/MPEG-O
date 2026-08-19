"""Vectorised slice parser and parallel producer tests.

SPDX-License-Identifier: Apache-2.0
"""
import numpy as np
import pytest

from ttio.importers.fastq import FastqParseError
from ttio.importers.fastq_parallel import parse_slice


def _fq(records, eol=b"\n"):
    out = bytearray()
    for name, seq, qual in records:
        out += b"@" + name + eol + seq + eol + b"+" + eol + qual + eol
    return bytes(out)


RECS = [(b"r0 extra tag", b"ACGT", b"II@I"),
        (b"r1", b"", b""),                       # zero-length read
        (b"r2", b"GGGGTTTT", b"JJJJKKKK")]


def _check(names, seq, qual, lens):
    assert names == ["r0", "r1", "r2"]
    assert bytes(seq) == b"ACGT" + b"" + b"GGGGTTTT"
    assert bytes(qual) == b"II@I" + b"" + b"JJJJKKKK"
    assert lens.tolist() == [4, 0, 8]
    assert lens.dtype == np.uint32


def test_clean_slice_fast_path():
    _check(*parse_slice(_fq(RECS)))


def test_crlf_slice():
    _check(*parse_slice(_fq(RECS, eol=b"\r\n")))


def test_stray_blank_line_falls_back():
    data = _fq(RECS[:1]) + b"\n" + _fq(RECS[1:])
    _check(*parse_slice(data))


def test_length_mismatch_raises():
    with pytest.raises(FastqParseError):
        parse_slice(_fq([(b"r0", b"ACGT", b"III")]))


def test_missing_trailing_newline():
    _check(*parse_slice(_fq(RECS)[:-1]))
