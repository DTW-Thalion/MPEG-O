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

import collections
import concurrent.futures as _cf
import io
import os

import numpy as np

from .._threads import pool_context
from ..written_genomic_run import WrittenGenomicRun
from .fasta import (
    _UNMAPPED_CHROM,
    _UNMAPPED_CIGAR,
    _UNMAPPED_FLAG,
    _UNMAPPED_MAPQ,
    _UNMAPPED_POS,
)
from .fastq import (
    PROGRESS_INTERVAL_READS,
    FastqParseError,
    _iter_fastq_records,
    detect_phred_offset,
)
from .fastq_scanner import boundary_at_or_after, confirm_candidate

__all__ = ["parse_slice", "plan_input", "iter_batches_pipeline"]


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


def plan_input(path, threads: int, batch_bytes: int):
    """``("serial", None)``, ``("pipeline", None)`` or
    ``("shard", ranges)`` for the input at ``path``: one thread or an
    empty file stays serial; gzip input (the ``1f 8b`` magic) cannot
    be sharded and pipelines; a plain file shards on scanner
    boundaries near multiples of
    ``max(batch_bytes, size // (threads * 4))``."""
    if threads <= 1:
        return "serial", None
    with open(path, "rb") as f:
        if f.read(2) == b"\x1f\x8b":
            return "pipeline", None
        size = os.fstat(f.fileno()).st_size
        if size == 0:
            return "serial", None
        target = max(batch_bytes, size // (threads * 4))
        cuts = [0]
        k = 1
        while k * target < size:
            b = boundary_at_or_after(f, k * target, size)
            if b >= size:
                break
            if b > cuts[-1]:
                cuts.append(b)
            k += 1
        return "shard", list(zip(cuts, cuts[1:] + [size]))


def _build_run(names, seq, qual, lens, meta) -> WrittenGenomicRun:
    n = len(names)
    if n == 0:
        raise FastqParseError(
            "input contains zero records; cannot build a genomic run")
    lens = lens.astype(np.uint32, copy=False)
    offsets = np.zeros(n, dtype=np.uint64)
    np.cumsum(lens[:-1], out=offsets[1:], dtype=np.uint64)
    return WrittenGenomicRun(
        acquisition_mode=int(meta["acquisition_mode"]),
        reference_uri=meta["reference_uri"],
        platform=meta["platform"],
        sample_name=meta["sample_name"],
        positions=np.full(n, _UNMAPPED_POS, dtype=np.int64),
        mapping_qualities=np.full(n, _UNMAPPED_MAPQ, dtype=np.uint8),
        flags=np.full(n, _UNMAPPED_FLAG, dtype=np.uint32),
        sequences=np.ascontiguousarray(seq, dtype=np.uint8),
        qualities=np.ascontiguousarray(qual, dtype=np.uint8),
        offsets=offsets,
        lengths=lens,
        cigars=[_UNMAPPED_CIGAR] * n,
        read_names=list(names),
        mate_chromosomes=[_UNMAPPED_CHROM] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=[_UNMAPPED_CHROM] * n,
    )


class _BatchAssembler:
    """Re-chunk an ordered stream of parsed slices into batches cut by
    the serial rule (``batch_reads`` records or ``batch_bytes``
    sequence bytes, whichever comes first), with the serial reader's
    Phred handling: the offset is forced or detected from the first
    emitted batch's quality bytes, and Phred+64 input is shifted to
    +33 at emit time."""

    def __init__(self, *, batch_reads, batch_bytes, forced, detected_cb, meta):
        self._batch_reads = batch_reads
        self._batch_bytes = batch_bytes
        self._offset = forced
        self._detected_cb = detected_cb
        self._meta = meta
        self._names: list = []
        self._seqs: list = []
        self._quals: list = []
        self._lens: list = []
        self._reads = 0
        self._bases = 0
        self._emitted = False

    def add(self, parsed):
        names, seq, qual, lens = parsed
        while len(names):
            cum = self._bases + np.cumsum(lens, dtype=np.int64)
            k_bytes = int(np.searchsorted(cum, self._batch_bytes, side="left")) + 1
            k_reads = self._batch_reads - self._reads
            k = min(k_bytes, k_reads)
            if k > len(names):
                self._push(names, seq, qual, lens)
                return
            head = int(lens[:k].sum())
            self._push(names[:k], seq[:head], qual[:head], lens[:k])
            yield self._emit()
            names, lens = names[k:], lens[k:]
            seq, qual = seq[head:], qual[head:]

    def finish(self):
        if self._reads or not self._emitted:
            yield self._emit()

    def _push(self, names, seq, qual, lens):
        self._names.extend(names)
        self._seqs.append(seq)
        self._quals.append(qual)
        self._lens.append(lens)
        self._reads += len(names)
        self._bases += int(lens.sum())

    def _emit(self):
        seq = np.concatenate(self._seqs) if self._seqs else np.empty(0, np.uint8)
        qual = np.concatenate(self._quals) if self._quals else np.empty(0, np.uint8)
        lens = (np.concatenate(self._lens) if self._lens
                else np.empty(0, np.uint32))
        if self._offset is None:
            self._offset = detect_phred_offset(qual.tobytes())
        if self._detected_cb is not None:
            self._detected_cb(self._offset)
        if self._offset == 64:
            qual = (qual - np.uint8(31)).astype(np.uint8)
        run = _build_run(self._names, seq, qual, lens, self._meta)
        self._names, self._seqs, self._quals, self._lens = [], [], [], []
        self._reads = self._bases = 0
        self._emitted = True
        return run


def _last_boundary(buf: bytes):
    """The largest confirmed record start in ``buf``, or ``None``."""
    a = np.frombuffer(buf, dtype=np.uint8)
    if a.size < 2:
        return None
    cand = np.nonzero((a[:-1] == 10) & (a[1:] == 64))[0] + 1
    for rel in cand[::-1].tolist():
        if confirm_candidate(buf, int(rel)) == 1:
            return int(rel)
    return None


def iter_batches_pipeline(path, *, threads, batch_reads, batch_bytes,
                          forced, detected_cb, meta, progress=None):
    """Pipeline mode: the caller thread reads (decompressed) chunks
    and slices them at record boundaries; the pool runs
    :func:`parse_slice`; batches emit in order through the assembler.
    The caller is submitter and consumer, so it pulls the head future
    before submitting once ``threads + 2`` slices are in flight."""
    from ..io.progress import _fire
    from .fasta import _open_maybe_gzip
    asm = _BatchAssembler(batch_reads=batch_reads, batch_bytes=batch_bytes,
                          forced=forced, detected_cb=detected_cb, meta=meta)
    n = 0

    def _count(run):
        # the serial reader fires every PROGRESS_INTERVAL_READS records
        nonlocal n
        before = n // PROGRESS_INTERVAL_READS
        n += len(run.lengths)
        for m in range(before + 1, n // PROGRESS_INTERVAL_READS + 1):
            _fire(progress, m * PROGRESS_INTERVAL_READS, -1)
        return run

    with pool_context(threads):
        pool = _cf.ThreadPoolExecutor(max_workers=threads,
                                      thread_name_prefix="ttio-fastq-parse")
        try:
            dq: collections.deque = collections.deque()
            carry = b""
            with _open_maybe_gzip(path) as fh:
                while True:
                    chunk = fh.read(batch_bytes)
                    if not chunk:
                        break
                    buf = carry + chunk
                    cut = _last_boundary(buf)
                    if not cut:
                        carry = buf
                        continue
                    while len(dq) >= threads + 2:
                        for run in asm.add(dq.popleft().result()):
                            yield _count(run)
                    dq.append(pool.submit(parse_slice, buf[:cut]))
                    carry = buf[cut:]
            if carry:
                dq.append(pool.submit(parse_slice, carry))
            while dq:
                for run in asm.add(dq.popleft().result()):
                    yield _count(run)
            for run in asm.finish():
                yield _count(run)
            _fire(progress, n, n)
        finally:
            pool.shutdown(wait=True, cancel_futures=True)
