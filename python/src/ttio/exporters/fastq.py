"""FASTQ exporter.

Writes a :class:`WrittenGenomicRun` to a FASTQ file with optional
gzip compression. Each read becomes a 4-line record:

    @read_name
    SEQUENCE
    +
    QUALITIES

The qualities channel is emitted verbatim (Phred+33 ASCII —
:class:`BamReader` and :class:`FastqReader` both store qualities in
this canonical form). For Phred+64 output, set ``phred_offset=64``;
each byte ``b`` is rewritten as ``b + 31`` on the way out.

Reads with an absent or all-``0xFF`` qualities buffer (the
``BamReader`` / FASTA-import sentinel for "qualities unknown") are
emitted with the ``!`` (Phred 0) fill character so the output is a
parseable FASTQ.

Cross-language byte-equality
----------------------------
For uncompressed output, three guarantees hold across Python, ObjC,
and Java:

1. Header is exactly ``@name\\n`` (description discarded).
2. The ``+`` separator line is exactly ``+\\n`` (no name repetition).
3. LF-only line endings.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOFastqWriter`` ·
Java: ``global.thalion.ttio.exporters.FastqWriter``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import gzip
import os
from pathlib import Path

from ..genomic_run import GenomicRun
from ..io.progress import ProgressSinkLike, _fire
from ..written_genomic_run import WrittenGenomicRun


__all__ = ["FastqWriter", "PROGRESS_INTERVAL_READS"]


_QUAL_UNKNOWN_BYTE = 0xFF
_PHRED33_FILL = ord("!")  # Phred 0 in Phred+33

#: Mirror Java's ``FastqWriter.PROGRESS_INTERVAL_READS``.
PROGRESS_INTERVAL_READS = 1000


class FastqWriter:
    """FASTQ exporter for unaligned genomic runs."""

    @classmethod
    def write(
        cls,
        run: WrittenGenomicRun | GenomicRun,
        path: str | os.PathLike[str],
        *,
        gzip_output: bool | None = None,
        phred_offset: int = 33,
        progress: ProgressSinkLike | None = None,
    ) -> None:
        """Serialise ``run`` to a FASTQ file.

        Parameters
        ----------
        run : WrittenGenomicRun
            Source run. The sequence and qualities channels must
            be the same length.
        path : str or Path
            Destination. ``.gz`` extension auto-enables gzip unless
            ``gzip_output`` is set explicitly.
        gzip_output : bool, optional
            Force gzip on (``True``) or off (``False``). When
            ``None`` (default), gzip is enabled iff ``path`` ends in
            ``.gz``.
        phred_offset : int
            ``33`` (default; modern Illumina / Sanger) or ``64``
            (legacy Illumina). Quality bytes are converted from the
            internal Phred+33 representation if ``64`` is selected.
        """
        if phred_offset not in (33, 64):
            raise ValueError(
                f"phred_offset must be 33 or 64 (got {phred_offset!r})"
            )
        out_path = Path(path)
        if gzip_output is None:
            gzip_output = out_path.name.lower().endswith(".gz")

        total = len(run.read_names) if isinstance(run, WrittenGenomicRun) else len(run)
        # Stream records straight to the handle: the output of a run is
        # its own size again, so buffering it (as before v1.9) doubled a
        # 20 GB export's footprint on top of the decode. Chunked writes
        # into one gzip stream produce the same bytes as a single write.
        opener = gzip.open(out_path, "wb") if gzip_output else out_path.open("wb")
        n = 0
        with opener as fh:
            for name, seq, qual in _iter_records(run, phred_offset=phred_offset):
                fh.write(b"@")
                fh.write(name.encode("utf-8"))
                fh.write(b"\n")
                fh.write(seq)
                fh.write(b"\n+\n")
                fh.write(qual)
                fh.write(b"\n")
                n += 1
                if n % PROGRESS_INTERVAL_READS == 0:
                    _fire(progress, n, total)
        _fire(progress, n, n)


def _iter_records(
    run: WrittenGenomicRun | GenomicRun, *, phred_offset: int,
):
    """Yield ``(name, seq_bytes, qual_bytes)`` per read in ``run``.

    Quality bytes are converted to the requested Phred offset and
    sentinel ``0xff`` qualities are mapped to Phred 0.

    For :class:`GenomicRun` (read-side, lazy) the loop iterates
    :meth:`GenomicRun.iter_reads`, which holds one decoded block at a
    time (blocks_v1) so a run of any size exports with bounded memory.
    """
    seen: set[str] = set()
    if isinstance(run, WrittenGenomicRun):
        records = (
            (
                run.read_names[i],
                bytes(run.sequences[int(run.offsets[i]):
                                    int(run.offsets[i]) + int(run.lengths[i])]),
                bytes(run.qualities[int(run.offsets[i]):
                                    int(run.offsets[i]) + int(run.lengths[i])]),
            )
            for i in range(len(run.read_names))
        )
    else:
        # Read-side: GenomicRun.iter_reads walks the run in order with
        # bounded memory (one decoded block at a time for blocks_v1,
        # the whole-channel caches for the v1.8 layout).
        def _records_iter():
            for r in run.iter_reads():
                yield (r.read_name, (r.sequence or "").encode("ascii"), bytes(r.qualities))
        records = _records_iter()
    for i, (name, seq, qual) in enumerate(records):
        # Map the unknown-quality sentinel to Phred 0 in the output.
        if qual and any(b == _QUAL_UNKNOWN_BYTE for b in qual):
            qual = bytes(
                (_PHRED33_FILL if b == _QUAL_UNKNOWN_BYTE else b) for b in qual
            )
        if phred_offset == 64:
            qual = bytes((b + 31) & 0xFF for b in qual)
        if not qual:
            # SAM-unmapped reads with seq absent: pad qualities to
            # the sequence length so the record stays parseable.
            qual = bytes([_PHRED33_FILL]) * len(seq)
            if phred_offset == 64:
                qual = bytes((b + 31) & 0xFF for b in qual)
        out_name = name
        if out_name in seen:
            out_name = f"{name}#{i}"
        seen.add(out_name)
        yield out_name, seq, qual
