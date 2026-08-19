"""Boundary scanner tests: the ``\\n@`` candidate rule confirmed by a
``+`` two lines down, window growth, and the truncated-final-record
case.

SPDX-License-Identifier: Apache-2.0
"""
import io

import pytest

from ttio.importers.fastq_scanner import boundary_at_or_after, confirm_candidate


def _fq(records):
    out = bytearray()
    for name, seq, qual in records:
        out += b"@" + name + b"\n" + seq + b"\n+\n" + qual + b"\n"
    return bytes(out)


def test_offset_zero_is_zero():
    data = _fq([(b"r0", b"ACGT", b"IIII")])
    assert boundary_at_or_after(io.BytesIO(data), 0, len(data)) == 0


def test_finds_next_record_start():
    data = _fq([(b"r0", b"ACGT", b"IIII"), (b"r1", b"GGGG", b"JJJJ")])
    second = data.index(b"@r1")
    for off in range(1, second + 1):
        assert boundary_at_or_after(io.BytesIO(data), off, len(data)) == second


def test_at_quality_candidate_rejected():
    # r0's quality line starts with '@': a candidate that must be
    # rejected (two lines down is r1's sequence, not '+').
    data = _fq([(b"r0", b"ACGT", b"@III"), (b"r1", b"GGGG", b"JJJJ")])
    qual_at = data.index(b"@III")
    second = data.index(b"@r1")
    assert boundary_at_or_after(io.BytesIO(data), qual_at - 1, len(data)) == second
    assert confirm_candidate(data, qual_at) == 0
    assert confirm_candidate(data, second) == 1


def test_candidate_on_window_edge_grows():
    # A long record forces the confirmation walk past the initial
    # window; the scanner must grow the window rather than reject.
    data = _fq([(b"r0", b"A" * 200, b"I" * 200), (b"r1", b"GGGG", b"JJJJ")])
    second = data.index(b"@r1")
    got = boundary_at_or_after(io.BytesIO(data), 1, len(data),
                               initial_window=16, max_window=4096)
    assert got == second
    assert confirm_candidate(data[:second + 2], second) == -1  # needs more bytes


def test_truncated_final_record_returns_size():
    data = _fq([(b"r0", b"ACGT", b"IIII")]) + b"@r1\nGG"
    trunc = data.index(b"@r1")
    assert boundary_at_or_after(io.BytesIO(data), trunc - 1, len(data)) == len(data)


def test_window_exhaustion_raises():
    # No confirmable boundary inside max_window while the file goes on.
    data = b"@r0\n" + b"A" * 5000 + b"\n+\n" + b"I" * 5000 + b"\n"
    from ttio.importers.fastq import FastqParseError
    with pytest.raises(FastqParseError):
        boundary_at_or_after(io.BytesIO(data), 1, len(data),
                             initial_window=16, max_window=64)
