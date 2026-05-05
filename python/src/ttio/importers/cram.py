"""CRAM importer — M88.

Reads CRAM (CRAM Reference-compressed Alignment Map) files via the
user-installed ``samtools`` binary as a subprocess. Subclasses
:class:`~ttio.importers.bam.BamReader` and reuses its SAM-text
parsing path: the only difference is that ``samtools view`` for CRAM
input requires a ``--reference <fasta>`` argument so the reference-
compressed sequence bytes can be reconstituted.

CRAM is the modern reference-compressed sequencing format used by
the 1000 Genomes Project, GA4GH RefGet workflows, and clinical
pipelines that need ~50% smaller files than BAM. Per Binding
Decision §139 the reference FASTA is a positional constructor
argument; no env-var fallback, no RefGet HTTP support in v0.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOCramReader`` · Java:
``global.thalion.ttio.importers.CramReader``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import numpy as np

from ..enums import AcquisitionMode
from ..provenance import ProvenanceRecord
from ..written_genomic_run import WrittenGenomicRun
from .bam import BamReader, _check_samtools


__all__ = ["CramReader"]


class CramReader(BamReader):
    """Read a CRAM file via the ``samtools view`` subprocess.

    Parameters
    ----------
    path : str or :class:`pathlib.Path`
        Filesystem path to a CRAM file.
    reference_fasta : str or :class:`pathlib.Path`
        Filesystem path to the reference FASTA against which the CRAM
        was aligned. Required (); CRAM is a
        reference-compressed format and cannot be decoded without it.
        samtools auto-builds a ``.fai`` index alongside the FASTA on
        first use if one isn't already present.

    Notes
    -----
    The ``samtools`` binary is a runtime dependency, not a build
    dependency. Construction succeeds without samtools on PATH;
    :meth:`to_genomic_run` raises
    :class:`~ttio.importers.bam.SamtoolsNotFoundError` when samtools
    cannot be located at first use (from M87).
    """

    def __init__(
        self,
        path: str | os.PathLike[str],
        reference_fasta: str | os.PathLike[str],
    ):
        super().__init__(path)
        self._reference_fasta = Path(reference_fasta)

    @property
    def reference_fasta(self) -> Path:
        return self._reference_fasta

    def to_genomic_run(
        self,
        name: str = "genomic_0001",
        region: str | None = None,
        sample_name: str | None = None,
    ) -> WrittenGenomicRun:
        """Read the CRAM and return a :class:`WrittenGenomicRun`.

        Identical semantics to
        :meth:`~ttio.importers.bam.BamReader.to_genomic_run` except
        that the underlying ``samtools view`` invocation includes
        ``--reference <reference_fasta>``.
        """
        _check_samtools()
        if not self._path.exists():
            raise FileNotFoundError(f"CRAM file not found: {self._path}")
        if not self._reference_fasta.exists():
            raise FileNotFoundError(
                f"Reference FASTA not found: {self._reference_fasta}"
            )

        cmd = [
            "samtools", "view", "-h",
            "--reference", str(self._reference_fasta),
            str(self._path),
        ]
        if region is not None:
            cmd.append(region)

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # The body below is intentionally structurally identical to
        # BamReader.to_genomic_run after the subprocess invocation —
        # CRAM and BAM produce the same SAM text downstream of the
        # ``view -h`` flag, so the parsing path is shared by copy
        # rather than by extraction (keeps the M87 BamReader source
        # untouched per the M88 plan).
        sq_names: list[str] = []
        rg_sample: str = ""
        rg_platform: str = ""
        provenance: list[ProvenanceRecord] = []

        read_names: list[str] = []
        chromosomes: list[str] = []
        positions_l: list[int] = []
        mapping_qualities_l: list[int] = []
        flags_l: list[int] = []
        cigars: list[str] = []
        mate_chromosomes: list[str] = []
        mate_positions_l: list[int] = []
        template_lengths_l: list[int] = []
        offsets_l: list[int] = []
        lengths_l: list[int] = []
        seq_chunks: list[bytes] = []
        qual_chunks: list[bytes] = []
        running_offset = 0

        try:
            file_mtime = int(self._path.stat().st_mtime)
        except OSError:
            file_mtime = int(time.time())

        try:
            assert proc.stdout is not None
            for line_no, raw_line in enumerate(proc.stdout, 1):
                line = raw_line.rstrip("\n")
                if not line:
                    continue
                if line.startswith("@"):
                    self._parse_header_line(
                        line,
                        sq_names=sq_names,
                        provenance=provenance,
                        rg_state=[rg_sample, rg_platform],
                        file_mtime=file_mtime,
                    )
                    if line.startswith("@RG") and not rg_sample:
                        sm, pl = self._parse_rg_fields(line)
                        if sm and not rg_sample:
                            rg_sample = sm
                        if pl and not rg_platform:
                            rg_platform = pl
                    continue

                cols = line.split("\t", 11)
                if len(cols) < 11:
                    raise RuntimeError(
                        f"Malformed SAM alignment at line {line_no}: "
                        f"expected >=11 tab-separated fields, got {len(cols)}"
                        f" — {line[:120]}"
                    )
                qname, flag_s, rname, pos_s, mapq_s, cigar, \
                    rnext, pnext_s, tlen_s, seq, qual = cols[:11]

                try:
                    flag = int(flag_s)
                    pos = int(pos_s)
                    mapq = int(mapq_s)
                    pnext = int(pnext_s)
                    tlen = int(tlen_s)
                except ValueError as exc:
                    raise RuntimeError(
                        f"Malformed SAM numeric field at line {line_no}: "
                        f"{exc} — {line[:120]}"
                    ) from exc

                if rnext == "=":
                    rnext = rname

                read_names.append(qname)
                flags_l.append(flag)
                chromosomes.append(rname)
                positions_l.append(pos)
                mapping_qualities_l.append(mapq)
                cigars.append(cigar)
                mate_chromosomes.append(rnext)
                mate_positions_l.append(pnext)
                template_lengths_l.append(tlen)

                if seq == "*":
                    seq_bytes = b""
                else:
                    seq_bytes = seq.encode("ascii")
                if qual == "*":
                    qual_bytes = b"" if seq == "*" else b"\xff" * len(seq_bytes)
                else:
                    qual_bytes = qual.encode("ascii")

                if len(qual_bytes) != len(seq_bytes):
                    if seq == "*":
                        qual_bytes = b""
                    elif qual == "*":
                        pass
                    else:
                        raise RuntimeError(
                            f"SEQ/QUAL length mismatch at line {line_no}: "
                            f"SEQ={len(seq_bytes)} QUAL={len(qual_bytes)}"
                        )

                length = len(seq_bytes)
                offsets_l.append(running_offset)
                lengths_l.append(length)
                seq_chunks.append(seq_bytes)
                qual_chunks.append(qual_bytes)
                running_offset += length

            proc.wait()
            if proc.returncode != 0:
                stderr_text = (proc.stderr.read()
                               if proc.stderr else "") or ""
                raise RuntimeError(
                    f"samtools view exited {proc.returncode} for "
                    f"{self._path}: {stderr_text.strip()[:500]}"
                )
        finally:
            try:
                if proc.stdout is not None:
                    proc.stdout.close()
            except Exception:
                pass
            try:
                if proc.stderr is not None:
                    proc.stderr.close()
            except Exception:
                pass
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()

        effective_sample = sample_name if sample_name is not None else rg_sample
        reference_uri = sq_names[0] if sq_names else ""

        positions = np.asarray(positions_l, dtype=np.int64)
        mapping_qualities = np.asarray(mapping_qualities_l, dtype=np.uint8)
        flags = np.asarray(flags_l, dtype=np.uint32)
        offsets = np.asarray(offsets_l, dtype=np.uint64)
        lengths = np.asarray(lengths_l, dtype=np.uint32)
        mate_positions = np.asarray(mate_positions_l, dtype=np.int64)
        template_lengths = np.asarray(template_lengths_l, dtype=np.int32)

        sequences = np.frombuffer(b"".join(seq_chunks), dtype=np.uint8).copy()
        qualities = np.frombuffer(b"".join(qual_chunks), dtype=np.uint8).copy()

        return WrittenGenomicRun(
            acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
            reference_uri=reference_uri,
            platform=rg_platform,
            sample_name=effective_sample,
            positions=positions,
            mapping_qualities=mapping_qualities,
            flags=flags,
            sequences=sequences,
            qualities=qualities,
            offsets=offsets,
            lengths=lengths,
            cigars=cigars,
            read_names=read_names,
            mate_chromosomes=mate_chromosomes,
            mate_positions=mate_positions,
            template_lengths=template_lengths,
            chromosomes=chromosomes,
            provenance_records=provenance,
        )
