"""FASTA exporter.

Writes a :class:`ReferenceImport` (preferred) or a
:class:`WrittenGenomicRun` to a FASTA file with optional gzip
compression and a samtools-compatible ``.fai`` index alongside.

Cross-language byte-equality
----------------------------
For uncompressed output, three guarantees hold across Python, ObjC,
and Java:

1. Header line is exactly ``>name\\n`` (no description preserved).
2. Sequence is wrapped at ``line_width`` bytes (default 60),
   verbatim case.
3. Line endings are LF only.

gzip-compressed output is *not* byte-equal across languages because
the compression libraries pick different choices; the conformance
harness diffs the decompressed payload.

The ``.fai`` index follows the samtools / htslib convention:

``<name>\\t<length>\\t<offset>\\t<linebases>\\t<linewidth>\\n``

* ``length``: total sequence length in bytes (no newlines).
* ``offset``: byte offset of the first sequence character after
  the header line.
* ``linebases``: ``line_width`` (sequence bytes per wrapped line).
* ``linewidth``: ``line_width + 1`` (includes terminal LF).

The trailing chromosome's final line may be short of
``line_width`` — the index records the canonical wrap width, not the
short tail, matching samtools' faidx output.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOFastaWriter`` ·
Java: ``global.thalion.ttio.exporters.FastaWriter``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import gzip
import io
import os
from pathlib import Path
from typing import Iterable

from ..genomic.reference_import import ReferenceImport
from ..genomic_run import GenomicRun
from ..written_genomic_run import WrittenGenomicRun


__all__ = ["FastaWriter", "DEFAULT_LINE_WIDTH"]


DEFAULT_LINE_WIDTH = 60


class FastaWriter:
    """FASTA exporter for reference imports and unaligned genomic runs.

    All methods are class-level; instantiation is unnecessary.
    """

    @classmethod
    def write_reference(
        cls,
        reference: ReferenceImport,
        path: str | os.PathLike[str],
        *,
        line_width: int = DEFAULT_LINE_WIDTH,
        gzip_output: bool | None = None,
        write_fai: bool = True,
    ) -> None:
        """Write a :class:`ReferenceImport` to a FASTA file.

        Parameters
        ----------
        reference : ReferenceImport
            Source reference. Chromosomes are written in the order
            recorded on the value class.
        path : str or Path
            Destination path. ``.gz`` extension auto-enables gzip
            unless ``gzip_output`` is set explicitly.
        line_width : int
            Sequence wrap width in bytes; default 60. Must be >= 1.
        gzip_output : bool, optional
            Force gzip on (``True``) or off (``False``). When
            ``None`` (default), gzip is enabled iff ``path`` ends in
            ``.gz``.
        write_fai : bool
            When ``True`` (default), emit a samtools-compatible
            ``<path>.fai`` index alongside. Index emission is
            skipped silently for gzip output (samtools faidx does
            not index plain gzip; bgzip is required and not yet
            supported here).
        """
        records = [
            (name, seq)
            for name, seq in zip(reference.chromosomes, reference.sequences)
        ]
        cls._write_records(
            records=records,
            path=Path(path),
            line_width=line_width,
            gzip_output=gzip_output,
            write_fai=write_fai,
        )

    @classmethod
    def write_run(
        cls,
        run: WrittenGenomicRun | GenomicRun,
        path: str | os.PathLike[str],
        *,
        line_width: int = DEFAULT_LINE_WIDTH,
        gzip_output: bool | None = None,
        write_fai: bool = True,
    ) -> None:
        """Write a genomic run to a FASTA file.

        Accepts either the write-side :class:`WrittenGenomicRun`
        (parallel arrays in memory) or the read-side
        :class:`GenomicRun` (lazy backing dataset). Each read becomes
        one FASTA record (``>read_name`` followed by the wrapped
        sequence). Quality bytes are discarded; use
        :class:`FastqWriter` to preserve them.
        """
        records = list(_iter_run_seqs(run))
        cls._write_records(
            records=records,
            path=Path(path),
            line_width=line_width,
            gzip_output=gzip_output,
            write_fai=write_fai,
        )

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    @classmethod
    def _write_records(
        cls,
        *,
        records: list[tuple[str, bytes]],
        path: Path,
        line_width: int,
        gzip_output: bool | None,
        write_fai: bool,
    ) -> None:
        if line_width < 1:
            raise ValueError(f"line_width must be >= 1 (got {line_width})")
        if gzip_output is None:
            gzip_output = path.name.lower().endswith(".gz")

        # Build the body in memory so we can compute the .fai offsets
        # in the same pass as writing. For very large references this
        # could be streamed; for v1.0 we accept the in-memory cost
        # (chr22 reference is ~50 MB, well within RAM).
        buf = io.BytesIO()
        fai_lines: list[str] = []
        for name, seq in records:
            hdr = ">" + name + "\n"
            buf.write(hdr.encode("utf-8"))
            seq_offset = buf.tell()
            length = len(seq)
            for start in range(0, length, line_width):
                chunk = seq[start : start + line_width]
                buf.write(chunk)
                buf.write(b"\n")
            fai_lines.append(
                f"{name}\t{length}\t{seq_offset}\t{line_width}\t{line_width + 1}"
            )
        body = buf.getvalue()

        if gzip_output:
            with gzip.open(path, "wb") as gz:
                gz.write(body)
        else:
            with path.open("wb") as fh:
                fh.write(body)

        if write_fai and not gzip_output:
            fai_path = path.with_suffix(path.suffix + ".fai")
            fai_path.write_text("\n".join(fai_lines) + "\n", encoding="ascii")


def _iter_run_seqs(
    run: WrittenGenomicRun | GenomicRun,
) -> Iterable[tuple[str, bytes]]:
    """Yield ``(read_name, sequence_bytes)`` per read in the run.

    Read names that collide are deduplicated by appending
    ``"#<index>"`` so the resulting FASTA is samtools-faidx safe
    (faidx requires unique sequence names).
    """
    seen: set[str] = set()
    if isinstance(run, WrittenGenomicRun):
        for i, name in enumerate(run.read_names):
            offset = int(run.offsets[i])
            length = int(run.lengths[i])
            seq_bytes = bytes(run.sequences[offset : offset + length])
            out_name = name
            if out_name in seen:
                out_name = f"{name}#{i}"
            seen.add(out_name)
            yield out_name, seq_bytes
    else:
        for i, read in enumerate(run):
            seq_bytes = read.sequence.encode("ascii")
            out_name = read.read_name
            if out_name in seen:
                out_name = f"{read.read_name}#{i}"
            seen.add(out_name)
            yield out_name, seq_bytes
