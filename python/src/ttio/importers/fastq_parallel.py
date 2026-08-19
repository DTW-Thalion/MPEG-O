"""Parallel FASTQ producer: vectorised slice parsing.

``parse_slice`` turns a byte slice that starts and ends on record
boundaries into ``(names, sequences, qualities, lengths)`` with numpy
doing the line geometry and byte gathers. The fast path assumes clean
four-line records; any validation mismatch re-parses the slice with
the tolerant serial loop, so stray blank lines cost speed, never
correctness. Qualities are verbatim (no Phred conversion); the
producer converts after detection, exactly as the serial reader does.

Cross-language equivalents: ``TTIOFastqParallelProducer`` (ObjC),
``FastqParallelProducer`` (Java).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io

import numpy as np

from .fastq import FastqParseError, _iter_fastq_records

__all__ = ["parse_slice"]


def _parse_slice_slow(data: bytes):
    names: list[str] = []
    seqs: list[bytes] = []
    quals: list[bytes] = []
    for name, seq, qual in _iter_fastq_records(io.BytesIO(data)):
        names.append(name)
        seqs.append(seq)
        quals.append(qual)
    lens = np.asarray([len(q) for q in seqs], dtype=np.uint32)
    return (names,
            np.frombuffer(b"".join(seqs), dtype=np.uint8).copy(),
            np.frombuffer(b"".join(quals), dtype=np.uint8).copy(),
            lens)


def _gather(a: np.ndarray, starts: np.ndarray, lens: np.ndarray) -> np.ndarray:
    total = int(lens.sum())
    if total == 0:
        return np.empty(0, dtype=np.uint8)
    excl = np.concatenate(([0], np.cumsum(lens)[:-1]))
    idx = np.arange(total, dtype=np.int64) + np.repeat(starts - excl, lens)
    return a[idx]


def parse_slice(data: bytes):
    """``(names, sequences_u8, qualities_u8_verbatim, lengths_u32)``
    for a slice that starts and ends on record boundaries."""
    a = np.frombuffer(data, dtype=np.uint8)
    if a.size == 0:
        return ([], np.empty(0, dtype=np.uint8),
                np.empty(0, dtype=np.uint8), np.empty(0, dtype=np.uint32))
    ends = np.nonzero(a == 10)[0]
    if data[-1] != 0x0A:
        ends = np.concatenate((ends, [a.size]))
    starts = np.empty_like(ends)
    starts[0] = 0
    starts[1:] = ends[:-1] + 1
    if len(starts) % 4 != 0:
        return _parse_slice_slow(data)
    # strip a trailing CR from non-empty lines
    stripped = ends.copy()
    mask = ends > starts
    stripped[mask] -= (a[ends[mask] - 1] == 13)
    hdr_s = starts[0::4]
    plus_s = starts[2::4]
    if not (np.all(a[hdr_s] == 64) and np.all(a[plus_s] == 43)):
        return _parse_slice_slow(data)
    seq_s, seq_e = starts[1::4], stripped[1::4]
    qual_s, qual_e = starts[3::4], stripped[3::4]
    seq_lens = seq_e - seq_s
    qual_lens = qual_e - qual_s
    if not np.array_equal(seq_lens, qual_lens):
        # a genuine mismatch or a grouping artifact: the tolerant
        # parser decides (and raises with the record's name)
        return _parse_slice_slow(data)
    names = []
    hdr_e = stripped[0::4]
    for hs, he in zip(hdr_s.tolist(), hdr_e.tolist()):
        names.append(data[hs + 1:he].split(None, 1)[0].decode("utf-8"))
    return (names,
            _gather(a, seq_s, seq_lens),
            _gather(a, qual_s, qual_lens),
            seq_lens.astype(np.uint32))
