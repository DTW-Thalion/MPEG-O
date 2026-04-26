"""SAM/BAM importer — M87.

Wraps the user-installed ``samtools`` binary as a subprocess to read
SAM and BAM (Sequence Alignment/Map) files into
:class:`~ttio.written_genomic_run.WrittenGenomicRun` instances. No
htslib source is linked or consulted; SAM/BAM format parsing is from
the public SAMv1 specification (https://samtools.github.io/hts-specs).

The subprocess approach mirrors :mod:`ttio.importers.thermo_raw`
(M38) and :mod:`ttio.importers.bruker_tdf` (M53). ``samtools`` is a
runtime dependency only — ``import ttio.importers.bam`` succeeds on
systems without samtools; only :meth:`BamReader.to_genomic_run`
requires the binary on PATH (Binding Decision §135).

samtools auto-detects SAM vs BAM format from magic bytes; one parser
handles both. The companion :class:`~ttio.importers.sam.SamReader`
exists as a discoverable convenience alias.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOBamReader`` · Java:
``global.thalion.ttio.importers.BamReader``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Iterable

import numpy as np

from ..enums import AcquisitionMode
from ..provenance import ProvenanceRecord
from ..written_genomic_run import WrittenGenomicRun


__all__ = ["BamReader", "SamtoolsNotFoundError"]


_INSTALL_HELP = (
    "samtools is required by ttio.importers.bam but was not found on "
    "PATH. Install it via your platform's package manager:\n"
    "  Debian/Ubuntu: apt install samtools\n"
    "  macOS:         brew install samtools\n"
    "  Conda:         conda install -c bioconda samtools\n"
    "Then re-run."
)


class SamtoolsNotFoundError(RuntimeError):
    """Raised at first use when ``samtools`` is not available on PATH.

    The class is a subclass of :class:`RuntimeError` so callers can
    catch it loosely; the message includes platform-appropriate
    install guidance (apt / brew / conda).
    """


def _samtools_on_path() -> bool:
    """Return True iff ``samtools`` is resolvable via :func:`shutil.which`."""
    return shutil.which("samtools") is not None


def _check_samtools() -> None:
    """Raise :class:`SamtoolsNotFoundError` if samtools is missing.

    Performs the PATH check via :func:`shutil.which` and additionally
    invokes ``samtools --version`` to verify the binary is callable.
    Per Binding Decision §135 this happens at first use, NOT at module
    import time.
    """
    if not _samtools_on_path():
        raise SamtoolsNotFoundError(_INSTALL_HELP)
    try:
        # capture binary; samtools --version prints copyright bytes
        # that aren't always strict UTF-8.
        proc = subprocess.run(
            ["samtools", "--version"],
            capture_output=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SamtoolsNotFoundError(
            f"{_INSTALL_HELP}\n(invocation failed: {exc})"
        ) from exc
    if proc.returncode != 0:
        stderr_text = (proc.stderr or b"").decode("utf-8", errors="replace")
        stdout_text = (proc.stdout or b"").decode("utf-8", errors="replace")
        raise SamtoolsNotFoundError(
            f"{_INSTALL_HELP}\n"
            f"(samtools --version exited {proc.returncode}: "
            f"{(stderr_text or stdout_text).strip()[:200]})"
        )


class BamReader:
    """Read a SAM or BAM file via the ``samtools view`` subprocess.

    Parameters
    ----------
    path : str or :class:`pathlib.Path`
        Filesystem path to a SAM or BAM file. samtools auto-detects
        the format from magic bytes.

    Notes
    -----
    The ``samtools`` binary is a runtime dependency, not a build
    dependency. Construction succeeds without samtools on PATH;
    :meth:`to_genomic_run` raises :class:`SamtoolsNotFoundError` when
    samtools cannot be located at first use (Binding Decision §135).
    """

    def __init__(self, path: str | os.PathLike[str]):
        self._path = Path(path)

    @property
    def path(self) -> Path:
        return self._path

    def to_genomic_run(
        self,
        name: str = "genomic_0001",
        region: str | None = None,
        sample_name: str | None = None,
    ) -> WrittenGenomicRun:
        """Read the BAM/SAM and return a :class:`WrittenGenomicRun`.

        Parameters
        ----------
        name : str
            The genomic-run name (becomes the subgroup name under
            ``/study/genomic_runs/<name>/``). Default
            ``"genomic_0001"``.
        region : str or None
            Optional region filter passed verbatim to
            ``samtools view`` (e.g. ``"chr1:1000-2000"`` or ``"*"``
            for unmapped reads).
        sample_name : str or None
            Optional override for the run's ``sample_name``. If
            ``None``, derived from the first ``@RG SM:`` tag in the
            header (or the empty string if no @RG present).

        Raises
        ------
        SamtoolsNotFoundError
            If ``samtools`` is not on PATH at first call.
        FileNotFoundError
            If the input path does not exist.
        RuntimeError
            If ``samtools view`` exits non-zero (stderr included in
            message) or if a SAM line is malformed.
        """
        _check_samtools()
        if not self._path.exists():
            raise FileNotFoundError(f"BAM/SAM file not found: {self._path}")

        cmd = ["samtools", "view", "-h", str(self._path)]
        if region is not None:
            cmd.append(region)

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Header state
        sq_names: list[str] = []
        rg_sample: str = ""
        rg_platform: str = ""
        provenance: list[ProvenanceRecord] = []

        # Per-read accumulators
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

        # Provenance timestamp comes from the file mtime per HANDOFF §2.4.
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
                    # rg_state mutation happens via local function; use
                    # a different style to avoid the closure trick:
                    if line.startswith("@RG") and not rg_sample:
                        sm, pl = self._parse_rg_fields(line)
                        if sm and not rg_sample:
                            rg_sample = sm
                        if pl and not rg_platform:
                            rg_platform = pl
                    continue

                # Alignment record. Per Gotcha §152, only fields 1-11
                # are parsed; trailing optional tags are discarded.
                # Use split with maxsplit=11 then take first 11 cols.
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

                # RNEXT special handling — Binding Decision §131:
                # "=" expands to RNAME so downstream consumers don't
                # need to remember the convention.
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

                # SEQ / QUAL: "*" means absent — contributes 0 bytes.
                # Per Gotcha §153 cigars[i] keeps "*" literally; SEQ/
                # QUAL are reduced to empty bytes in the buffer (the
                # offsets/lengths pair carries the "absent" signal).
                if seq == "*":
                    seq_bytes = b""
                else:
                    seq_bytes = seq.encode("ascii")
                if qual == "*":
                    qual_bytes = b"" if seq == "*" else b"\xff" * len(seq_bytes)
                else:
                    qual_bytes = qual.encode("ascii")

                # SAM spec: SEQ and QUAL must be the same length when
                # both present. We don't try to "fix" inputs; we
                # truncate qual to seq length if mismatched (samtools
                # already validated on the wire side).
                if len(qual_bytes) != len(seq_bytes):
                    if seq == "*":
                        # SEQ absent but qual present — discard qual.
                        qual_bytes = b""
                    elif qual == "*":
                        # Already handled above (filled to seq length).
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

        # Apply sample_name override per Binding Decision §133.
        effective_sample = sample_name if sample_name is not None else rg_sample

        # reference_uri: first @SQ wins for v0 of M87 (HANDOFF §2.4).
        # Empty string when no @SQ present.
        reference_uri = sq_names[0] if sq_names else ""

        # Build numpy arrays.
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

    # ------------------------------------------------------------------
    # Header-line parsing helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _parse_header_fields(line: str) -> dict[str, str]:
        """Split a SAM header line into a {KEY: VALUE} dict.

        Skips the leading ``@TAG`` token. Tolerates fields that lack
        a colon by silently dropping them (samtools never emits
        these but be defensive).
        """
        fields: dict[str, str] = {}
        for token in line.split("\t")[1:]:
            if ":" not in token:
                continue
            k, _, v = token.partition(":")
            fields[k] = v
        return fields

    @classmethod
    def _parse_rg_fields(cls, line: str) -> tuple[str, str]:
        """Return (sample, platform) from an ``@RG`` header line."""
        fields = cls._parse_header_fields(line)
        return fields.get("SM", ""), fields.get("PL", "")

    @classmethod
    def _parse_header_line(
        cls,
        line: str,
        *,
        sq_names: list[str],
        provenance: list[ProvenanceRecord],
        rg_state: list[str],   # unused; kept for legacy signature
        file_mtime: int,
    ) -> None:
        """Dispatch a header line to the appropriate accumulator.

        Only @SQ and @PG are accumulated into structured state here;
        @RG is handled inline in :meth:`to_genomic_run` so the
        first-wins rule (Binding Decision §133) is obvious at the
        callsite. @HD and @CO are read but not mapped to TTI-O
        fields in v0 (HANDOFF §2.4).
        """
        if line.startswith("@SQ"):
            fields = cls._parse_header_fields(line)
            sn = fields.get("SN")
            if sn:
                sq_names.append(sn)
        elif line.startswith("@PG"):
            fields = cls._parse_header_fields(line)
            program = fields.get("PN", "")
            command_line = fields.get("CL", "")
            params: dict[str, object] = {}
            if command_line:
                params["CL"] = command_line
            for k in ("ID", "VN", "PP"):
                if k in fields:
                    params[k] = fields[k]
            provenance.append(
                ProvenanceRecord(
                    timestamp_unix=file_mtime,
                    software=program,
                    parameters=params,
                )
            )
        # @HD, @CO, @RG: handled elsewhere or ignored in v0.
