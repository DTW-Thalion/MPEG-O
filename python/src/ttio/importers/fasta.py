"""FASTA importer.

Parses FASTA files into either a :class:`ReferenceImport` (for
reference genomes that pair with BAM/CRAM input) or an unaligned
:class:`WrittenGenomicRun` (for amplicon panels, target lists, or
quality-stripped reads).

Supports gzip-compressed input transparently (detected via magic
bytes ``1f 8b``). FASTA records are header-line ``>name [desc...]``
followed by one or more sequence lines until the next header or EOF.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOFastaReader`` ·
Java: ``global.thalion.ttio.importers.FastaReader``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import gzip
import io
import os
from pathlib import Path
from typing import Iterator

import numpy as np

from ..enums import AcquisitionMode
from ..genomic.reference_import import ReferenceImport
from ..written_genomic_run import WrittenGenomicRun


__all__ = ["FastaReader", "FastaParseError"]


# SAM unmapped sentinel values for unaligned reads imported from FASTA.
_UNMAPPED_FLAG = 4
_UNMAPPED_CHROM = "*"
_UNMAPPED_POS = 0
_UNMAPPED_MAPQ = 255  # SAM "MAPQ unavailable"
_UNMAPPED_CIGAR = "*"
_UNMAPPED_QUAL_BYTE = 0xFF  # "qualities unknown" sentinel matching BamReader


class FastaParseError(RuntimeError):
    """Raised on malformed FASTA input (missing header, embedded
    null byte, header without sequence)."""


def _open_maybe_gzip(path: Path) -> io.BufferedReader:
    """Open ``path`` for reading bytes, transparently decompressing
    if it is a gzip file (detected by the ``1f 8b`` magic regardless
    of file extension)."""
    fh = open(path, "rb")
    magic = fh.peek(2)[:2]
    if magic == b"\x1f\x8b":
        fh.close()
        return gzip.open(path, "rb")  # type: ignore[return-value]
    return fh


def _iter_records(stream: io.BufferedReader) -> Iterator[tuple[str, bytes]]:
    """Yield ``(name, sequence_bytes)`` for every record in ``stream``.

    Header parsing: name is the first whitespace-delimited token after
    ``>``. Description (if any) is discarded — round-trip is
    name-only.
    """
    name: str | None = None
    chunks: list[bytes] = []
    for raw in stream:
        line = raw.rstrip(b"\r\n")
        if not line:
            continue
        if line.startswith(b">"):
            if name is not None:
                yield name, b"".join(chunks)
                chunks = []
            hdr = line[1:].split(None, 1)
            if not hdr or not hdr[0]:
                raise FastaParseError(
                    "FASTA header missing a name token (line starts with '>')"
                )
            name = hdr[0].decode("utf-8")
        else:
            if name is None:
                raise FastaParseError(
                    "FASTA sequence bytes encountered before any header line"
                )
            chunks.append(line)
    if name is not None:
        yield name, b"".join(chunks)


class FastaReader:
    """Read a FASTA file into TTI-O containers.

    Parameters
    ----------
    path : str or Path
        Filesystem path to a ``.fa`` / ``.fasta`` / ``.fna`` file.
        gzip-compressed inputs (``.fa.gz`` etc.) are auto-detected
        and decompressed.

    Notes
    -----
    Construction reads only the file header (or nothing). Calling
    :meth:`read_reference` or :meth:`read_unaligned` triggers the
    full parse.
    """

    def __init__(self, path: str | os.PathLike[str]):
        self._path = Path(path)
        if not self._path.exists():
            raise FileNotFoundError(f"FASTA file not found: {self._path}")

    @property
    def path(self) -> Path:
        return self._path

    # ------------------------------------------------------------------
    # Reference mode
    # ------------------------------------------------------------------

    def read_reference(self, uri: str | None = None) -> ReferenceImport:
        """Parse the file as a reference genome.

        Each FASTA record becomes one chromosome.

        Parameters
        ----------
        uri : str, optional
            Reference URI to record on the resulting
            :class:`ReferenceImport`. Defaults to the file's stem
            (e.g. ``"GRCh38"`` for ``GRCh38.fa``), with ``.fa.gz``
            and ``.fasta.gz`` compound suffixes stripped.

        Returns
        -------
        ReferenceImport
            Value class carrying chromosomes, sequences (case-
            preserving), and content MD5.
        """
        names: list[str] = []
        seqs: list[bytes] = []
        with _open_maybe_gzip(self._path) as fh:
            for name, seq in _iter_records(fh):
                names.append(name)
                seqs.append(seq)
        if not names:
            raise FastaParseError(
                f"no FASTA records found in {self._path}"
            )
        if uri is None:
            uri = _derive_uri(self._path)
        return ReferenceImport(uri=uri, chromosomes=names, sequences=seqs)

    # ------------------------------------------------------------------
    # Unaligned-run mode
    # ------------------------------------------------------------------

    def read_unaligned(
        self,
        *,
        sample_name: str = "",
        platform: str = "",
        reference_uri: str = "",
        acquisition_mode: AcquisitionMode = AcquisitionMode.GENOMIC_WGS,
    ) -> WrittenGenomicRun:
        """Parse the file as a set of unaligned reads.

        Each FASTA record becomes one read with SAM-unmapped sentinel
        values: ``flags = 4`` (unmapped), ``chromosome = "*"``,
        ``position = 0``, ``mapq = 255``, ``cigar = "*"``. The
        ``qualities`` channel is filled with ``0xff`` bytes (one per
        base, matching :class:`BamReader`'s convention for SAM
        records whose QUAL field is ``*``).

        Parameters
        ----------
        sample_name : str
            Recorded on the genomic run; default ``""``.
        platform : str
            Sequencing platform tag (e.g. ``"ILLUMINA"``); default
            ``""``.
        reference_uri : str
            Reference URI to associate with this run; default
            ``""`` (no reference).
        acquisition_mode : AcquisitionMode
            Run-level acquisition mode; default ``GENOMIC_WGS``.

        Returns
        -------
        WrittenGenomicRun
            Run container ready to pass to
            :meth:`SpectralDataset.write_minimal` via
            ``genomic_runs=[...]``.
        """
        return _build_unaligned_run(
            iter_records=lambda: self._iter_record_pairs(quality_default=None),
            sample_name=sample_name,
            platform=platform,
            reference_uri=reference_uri,
            acquisition_mode=acquisition_mode,
        )

    def _iter_record_pairs(
        self, *, quality_default: bytes | None
    ) -> Iterator[tuple[str, bytes, bytes]]:
        """Iterator yielding (name, seq, qual) triples — qual filled
        with the unmapped sentinel ``0xff`` bytes."""
        with _open_maybe_gzip(self._path) as fh:
            for name, seq in _iter_records(fh):
                if quality_default is None:
                    qual = bytes([_UNMAPPED_QUAL_BYTE]) * len(seq)
                else:
                    qual = quality_default * len(seq)
                yield name, seq, qual


def _derive_uri(path: Path) -> str:
    """Strip ``.gz``, then strip ``.fa`` / ``.fasta`` / ``.fna`` /
    ``.fastq`` / ``.fq`` to produce the URI stem."""
    name = path.name
    for ext in (".gz",):
        if name.lower().endswith(ext):
            name = name[: -len(ext)]
            break
    for ext in (".fasta", ".fastq", ".fna", ".fa", ".fq"):
        if name.lower().endswith(ext):
            name = name[: -len(ext)]
            break
    return name


def _build_unaligned_run(
    *,
    iter_records,
    sample_name: str,
    platform: str,
    reference_uri: str,
    acquisition_mode: AcquisitionMode,
) -> WrittenGenomicRun:
    """Build a :class:`WrittenGenomicRun` from a (name, seq, qual)
    iterator. Shared between FASTA and FASTQ unaligned imports.
    """
    read_names: list[str] = []
    seq_chunks: list[bytes] = []
    qual_chunks: list[bytes] = []
    offsets_l: list[int] = []
    lengths_l: list[int] = []
    running = 0
    n_reads = 0
    for name, seq, qual in iter_records():
        if len(seq) != len(qual):
            raise FastaParseError(
                f"SEQ/QUAL length mismatch for read {name!r}: "
                f"{len(seq)} vs {len(qual)}"
            )
        read_names.append(name)
        offsets_l.append(running)
        lengths_l.append(len(seq))
        seq_chunks.append(seq)
        qual_chunks.append(qual)
        running += len(seq)
        n_reads += 1
    if n_reads == 0:
        raise FastaParseError(
            "input contains zero records; cannot build a genomic run"
        )

    chromosomes = [_UNMAPPED_CHROM] * n_reads
    cigars = [_UNMAPPED_CIGAR] * n_reads
    mate_chromosomes = [_UNMAPPED_CHROM] * n_reads

    return WrittenGenomicRun(
        acquisition_mode=int(acquisition_mode),
        reference_uri=reference_uri,
        platform=platform,
        sample_name=sample_name,
        positions=np.full(n_reads, _UNMAPPED_POS, dtype=np.int64),
        mapping_qualities=np.full(n_reads, _UNMAPPED_MAPQ, dtype=np.uint8),
        flags=np.full(n_reads, _UNMAPPED_FLAG, dtype=np.uint32),
        sequences=np.frombuffer(b"".join(seq_chunks), dtype=np.uint8).copy(),
        qualities=np.frombuffer(b"".join(qual_chunks), dtype=np.uint8).copy(),
        offsets=np.asarray(offsets_l, dtype=np.uint64),
        lengths=np.asarray(lengths_l, dtype=np.uint32),
        cigars=cigars,
        read_names=read_names,
        mate_chromosomes=mate_chromosomes,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=chromosomes,
    )
