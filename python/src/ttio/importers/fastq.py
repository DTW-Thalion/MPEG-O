"""FASTQ importer.

Parses FASTQ files into unaligned :class:`WrittenGenomicRun`
instances. Each four-line record (``@name``, sequence, ``+``,
qualities) becomes one read; the SAM unmapped flags
(``flags = 4``, ``chrom = "*"``, ``pos = 0``, ``mapq = 255``,
``cigar = "*"``) are written so the resulting run is internally
consistent with FASTA-imported runs and with SAM-unmapped reads.

Phred encoding is auto-detected by scanning the qualities bytes:

* If any quality byte is below ASCII ``59`` (Phred+33 score < 26),
  the file is Phred+33.
* Otherwise, if every observed byte is in ``[64, 104]``, the file
  is treated as Phred+64 and converted to Phred+33 on the fly
  (each byte ``b`` becomes ``b - 31``).
* Tie-break: Phred+33 (modern Illumina default).

The detected offset is exposed via
:attr:`FastqReader.detected_phred_offset`. Pass
``force_phred=33`` or ``force_phred=64`` to override the heuristic.

Compressed input (``.fq.gz`` / ``.fastq.gz``) is auto-detected via
the ``1f 8b`` magic bytes regardless of file extension.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOFastqReader`` ·
Java: ``global.thalion.ttio.importers.FastqReader``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Iterator

from ..enums import AcquisitionMode
from ..written_genomic_run import WrittenGenomicRun
from .fasta import (
    FastaParseError,
    _build_unaligned_run,
    _open_maybe_gzip,
)


__all__ = ["FastqReader", "FastqParseError", "detect_phred_offset"]


# Re-export under the FASTQ name so callers can catch a parser-
# specific class without depending on ``ttio.importers.fasta``.
class FastqParseError(FastaParseError):
    """Raised on malformed FASTQ input (not a multiple of 4 lines,
    SEQ/QUAL length mismatch, missing ``+`` separator)."""


def detect_phred_offset(qualities: bytes) -> int:
    """Heuristic offset detection over a quality-bytes sample.

    Parameters
    ----------
    qualities : bytes
        Concatenated quality bytes (one or more records).

    Returns
    -------
    int
        ``33`` (modern Illumina, Sanger) or ``64`` (legacy Illumina /
        Solexa pre-1.8). Empty input returns ``33``.

    Notes
    -----
    The detection rule is:

    * any byte ``b < 59`` => Phred+33 (Phred+64 starts at ``b == 64``)
    * else if every byte is in ``[64, 104]`` => Phred+64
    * else => Phred+33 (default)
    """
    if not qualities:
        return 33
    lo = min(qualities)
    if lo < 59:
        return 33
    hi = max(qualities)
    if 64 <= lo and hi <= 104:
        return 64
    return 33


class FastqReader:
    """Read a FASTQ file into a :class:`WrittenGenomicRun`.

    Parameters
    ----------
    path : str or Path
        Filesystem path to a ``.fq`` / ``.fastq`` file
        (``.fq.gz`` / ``.fastq.gz`` auto-detected).
    force_phred : int, optional
        ``33`` or ``64`` to bypass auto-detection. Defaults to
        ``None`` (auto-detect).
    """

    def __init__(
        self,
        path: str | os.PathLike[str],
        *,
        force_phred: int | None = None,
    ):
        self._path = Path(path)
        if not self._path.exists():
            raise FileNotFoundError(f"FASTQ file not found: {self._path}")
        if force_phred not in (None, 33, 64):
            raise ValueError(
                f"force_phred must be 33 or 64 (got {force_phred!r})"
            )
        self._forced = force_phred
        self._detected: int | None = None

    @property
    def path(self) -> Path:
        return self._path

    @property
    def detected_phred_offset(self) -> int:
        """Phred offset (33 or 64) actually applied to the most
        recent :meth:`read` call. ``KeyError`` if read hasn't been
        called yet."""
        if self._detected is None:
            raise KeyError("call FastqReader.read() first")
        return self._detected

    def read(
        self,
        *,
        sample_name: str = "",
        platform: str = "",
        reference_uri: str = "",
        acquisition_mode: AcquisitionMode = AcquisitionMode.GENOMIC_WGS,
    ) -> WrittenGenomicRun:
        """Parse the file and return a :class:`WrittenGenomicRun`.

        Quality bytes are normalised to Phred+33 internally
        (verbatim ASCII storage) so downstream codecs see a single
        canonical representation. The detected source offset is
        recorded on :attr:`detected_phred_offset` for round-trip.

        Parameters
        ----------
        sample_name : str
            Recorded on the run; default ``""``.
        platform : str
            Sequencing platform tag; default ``""``.
        reference_uri : str
            Reference URI to associate with this run; default ``""``.
        acquisition_mode : AcquisitionMode
            Default ``GENOMIC_WGS``.

        Returns
        -------
        WrittenGenomicRun
            Unaligned run ready for ``SpectralDataset.write_minimal``.
        """
        if self._forced is not None:
            offset = self._forced
            triples = list(self._iter_with_offset(offset))
        else:
            triples = list(self._iter_records_raw())
            qual_concat = b"".join(q for _, _, q in triples)
            offset = detect_phred_offset(qual_concat)
            if offset == 64:
                triples = [
                    (n, s, bytes((b - 31) & 0xFF for b in q))
                    for (n, s, q) in triples
                ]
        self._detected = offset

        def _iter():
            yield from triples

        return _build_unaligned_run(
            iter_records=_iter,
            sample_name=sample_name,
            platform=platform,
            reference_uri=reference_uri,
            acquisition_mode=acquisition_mode,
        )

    def _iter_records_raw(self) -> Iterator[tuple[str, bytes, bytes]]:
        """Yield ``(name, seq, qual)`` with quality bytes verbatim
        (no Phred conversion)."""
        with _open_maybe_gzip(self._path) as fh:
            line_no = 0
            while True:
                hdr = fh.readline()
                if not hdr:
                    return
                line_no += 1
                hdr = hdr.rstrip(b"\r\n")
                if not hdr:
                    continue  # tolerate stray blank lines between records
                if not hdr.startswith(b"@"):
                    raise FastqParseError(
                        f"line {line_no}: expected '@<name>' header, "
                        f"got {hdr[:60]!r}"
                    )
                name = hdr[1:].split(None, 1)[0].decode("utf-8")
                seq_line = fh.readline()
                line_no += 1
                if not seq_line:
                    raise FastqParseError(
                        f"truncated record at line {line_no} "
                        f"(missing sequence)"
                    )
                seq = seq_line.rstrip(b"\r\n")
                plus = fh.readline()
                line_no += 1
                if not plus or not plus.startswith(b"+"):
                    raise FastqParseError(
                        f"line {line_no}: expected '+' separator, "
                        f"got {plus[:60]!r}"
                    )
                qual_line = fh.readline()
                line_no += 1
                if not qual_line:
                    raise FastqParseError(
                        f"truncated record at line {line_no} "
                        f"(missing qualities)"
                    )
                qual = qual_line.rstrip(b"\r\n")
                if len(qual) != len(seq):
                    raise FastqParseError(
                        f"line {line_no}: SEQ/QUAL length mismatch "
                        f"({len(seq)} vs {len(qual)}) for read {name!r}"
                    )
                yield name, seq, qual

    def _iter_with_offset(
        self, offset: int
    ) -> Iterator[tuple[str, bytes, bytes]]:
        """Iterate records, converting Phred+64 to Phred+33 if
        ``offset == 64``."""
        for name, seq, qual in self._iter_records_raw():
            if offset == 64:
                qual = bytes((b - 31) & 0xFF for b in qual)
            yield name, seq, qual
