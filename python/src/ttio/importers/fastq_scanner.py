"""FASTQ record-boundary scanner.

Finds the first record start at or after a byte offset without parsing
from the file head: a ``\\n@`` candidate is a record boundary iff the
line two lines down starts with ``+`` (quality bytes legally contain
``@``, but a sequence line never starts with ``+``). The scan window
starts at 1 MiB and doubles to 16 MiB before giving up, so a record
longer than the window is an error rather than a wrong cut.

Cross-language equivalents: ``TTIOFastqRecordScanner`` (ObjC),
``FastqRecordScanner`` (Java).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import numpy as np

from .fastq import FastqParseError

__all__ = ["boundary_at_or_after", "confirm_candidate"]

INITIAL_WINDOW = 1 * 2**20
MAX_WINDOW = 16 * 2**20


def confirm_candidate(buf: bytes, pos: int) -> int:
    """Is ``buf[pos]`` (an ``@`` at a line start) a record header?

    Returns ``1`` (confirmed: the line two lines down starts with
    ``+``), ``0`` (rejected), or ``-1`` (the buffer ends before the
    rule can be applied; the caller needs more bytes).
    """
    end0 = buf.find(b"\n", pos)
    if end0 < 0:
        return -1
    end1 = buf.find(b"\n", end0 + 1)
    if end1 < 0:
        return -1
    if end1 + 1 >= len(buf):
        return -1
    return 1 if buf[end1 + 1:end1 + 2] == b"+" else 0


def boundary_at_or_after(f, offset: int, file_size: int, *,
                         initial_window: int = INITIAL_WINDOW,
                         max_window: int = MAX_WINDOW) -> int:
    """The byte offset of the first record start at or after
    ``offset`` in the seekable binary file ``f``, or ``file_size``
    when no further complete record starts (a truncated tail belongs
    to the previous shard, which parses to the error)."""
    if offset <= 0:
        return 0
    if offset >= file_size:
        return file_size
    start = offset - 1  # include a possible newline just before offset
    window = initial_window
    while True:
        f.seek(start)
        buf = f.read(min(window, file_size - start))
        at_eof = start + len(buf) >= file_size
        a = np.frombuffer(buf, dtype=np.uint8)
        cand = (np.nonzero((a[:-1] == 10) & (a[1:] == 64))[0] + 1
                if len(a) > 1 else np.empty(0, dtype=np.int64))
        need_more = False
        for rel in cand:
            rel = int(rel)
            r = confirm_candidate(buf, rel)
            if r == 1:
                return start + rel
            if r == -1 and not at_eof:
                need_more = True
                break
        if at_eof and not need_more:
            return file_size
        window *= 2
        if window > max_window:
            raise FastqParseError(
                f"no FASTQ record boundary within {max_window} bytes "
                f"after offset {offset}; record longer than the scan "
                f"window or not FASTQ")
