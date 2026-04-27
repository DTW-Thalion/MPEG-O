"""BAM exporter — M88.

Writes a :class:`~ttio.written_genomic_run.WrittenGenomicRun` to BAM
by formatting the in-memory parallel-array representation as SAM
text and piping that text via stdin to the user-installed
``samtools`` binary (``samtools view -bS -``, optionally piped
through ``samtools sort -O bam``). Subprocess-only — no htslib
linkage; SAM line layout is from the public SAMv1 spec.

Quality byte encoding
---------------------
M87's :class:`~ttio.importers.bam.BamReader` stores SAM's QUAL field
bytes verbatim into ``WrittenGenomicRun.qualities`` — i.e. the
buffer holds **ASCII Phred+33** characters (so a Phred-40 score is
stored as the byte value 73, the ASCII code for ``'I'``). This
writer mirrors that convention: each ``qualities[i]`` byte is
written directly as the SAM QUAL character with no arithmetic
adjustment. The pair is therefore lossless byte-for-byte across the
M87 read → M88 write round trip.

Cross-language note: ObjC and Java implementations must adopt the
same convention (store QUAL bytes verbatim on read; emit them
verbatim on write) so that conformance dumps match.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOBamWriter`` · Java:
``global.thalion.ttio.exporters.BamWriter``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Iterable

from ..importers.bam import _check_samtools
from ..provenance import ProvenanceRecord
from ..written_genomic_run import WrittenGenomicRun


__all__ = ["BamWriter"]


# Default @SQ length when the writer doesn't know the true reference
# length. SAM requires LN: on every @SQ; we pick INT32_MAX so the
# emitted header is valid for any plausible coordinate. samtools'
# downstream consumers (IGV, GATK) accept this fallback. The same
# value should be used by the ObjC and Java writers for cross-
# language byte-equality on the unsorted code path.
_DEFAULT_SQ_LENGTH = 2147483647


class BamWriter:
    """Write a :class:`~ttio.written_genomic_run.WrittenGenomicRun` to BAM.

    Parameters
    ----------
    path : str or :class:`pathlib.Path`
        Output BAM file path. The ``.bam`` extension is honoured by
        samtools' file-format auto-detection (Gotcha §165).

    Notes
    -----
    The ``samtools`` binary is a runtime dependency. Construction
    succeeds without samtools on PATH; :meth:`write` raises
    :class:`~ttio.importers.bam.SamtoolsNotFoundError` when samtools
    is missing at first call (Binding Decision §135 from M87).
    """

    def __init__(self, path: str | os.PathLike[str]):
        self._path = Path(path)

    @property
    def path(self) -> Path:
        return self._path

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def write(
        self,
        run: WrittenGenomicRun,
        provenance_records: list[ProvenanceRecord] | None = None,
        sort: bool = True,
    ) -> None:
        """Serialise ``run`` to the configured output path.

        Parameters
        ----------
        run : WrittenGenomicRun
            The genomic-run container to write.
        provenance_records : list[ProvenanceRecord] or None
            Optional provenance records to inject as ``@PG`` header
            lines. If ``None``, falls back to ``run.provenance_records``
            so the most common Python-side call is one-arg. Java and
            ObjC pass this explicitly because their
            ``WrittenGenomicRun`` analogues don't carry provenance.
        sort : bool, default True
            When ``True`` (the default per Binding Decision §137),
            pipes the SAM text through ``samtools sort -O bam`` so
            the output BAM is coordinate-sorted (the precondition
            most BAM consumers expect — IGV, GATK, ``samtools
            index``). When ``False``, output is written in the input
            ``run``'s read order and the ``@HD SO:`` tag is set to
            ``unsorted``.
        """
        _check_samtools()

        if provenance_records is None:
            provenance_records = list(run.provenance_records)

        sam_text = self._build_sam_text(
            run, provenance_records, sort=sort,
        )

        self._invoke_samtools(sam_text, sort=sort)

    # ------------------------------------------------------------------
    # SAM text assembly
    # ------------------------------------------------------------------

    def _build_sam_text(
        self,
        run: WrittenGenomicRun,
        provenance_records: list[ProvenanceRecord],
        *,
        sort: bool,
    ) -> str:
        """Build the full SAM text (header + alignment lines)."""
        parts: list[str] = []
        parts.append(self._build_header(run, provenance_records, sort=sort))
        parts.extend(self._iter_alignment_lines(run))
        # Trailing newline keeps samtools happy on some platforms.
        return "".join(parts)

    @staticmethod
    def _build_header(
        run: WrittenGenomicRun,
        provenance_records: list[ProvenanceRecord],
        *,
        sort: bool,
    ) -> str:
        """Emit the @HD / @SQ / @RG / @PG header block."""
        lines: list[str] = []

        so = "coordinate" if sort else "unsorted"
        lines.append(f"@HD\tVN:1.6\tSO:{so}")

        # @SQ — one per unique chromosome (excluding "*" which is
        # the SAM unmapped sentinel and not a real reference). Emit
        # in first-seen order so writer output is deterministic.
        seen: set[str] = set()
        for chrom in run.chromosomes:
            if not chrom or chrom == "*" or chrom in seen:
                continue
            seen.add(chrom)
            lines.append(f"@SQ\tSN:{chrom}\tLN:{_DEFAULT_SQ_LENGTH}")

        # @RG — single line if either sample_name or platform is set.
        if run.sample_name or run.platform:
            rg_parts = ["@RG", "ID:rg1"]
            if run.sample_name:
                rg_parts.append(f"SM:{run.sample_name}")
            if run.platform:
                rg_parts.append(f"PL:{run.platform}")
            lines.append("\t".join(rg_parts))

        # @PG — one line per provenance record. SAM requires ID;
        # synthesize "pg<idx>" if the record's software field is
        # blank or collides.
        used_ids: set[str] = set()
        for idx, prov in enumerate(provenance_records):
            base_id = prov.software or f"pg{idx}"
            pg_id = base_id
            n = 1
            while pg_id in used_ids:
                pg_id = f"{base_id}.{n}"
                n += 1
            used_ids.add(pg_id)
            pg_parts = [
                "@PG",
                f"ID:{pg_id}",
                f"PN:{prov.software}",
            ]
            cl = prov.parameters.get("CL") if prov.parameters else None
            if cl:
                pg_parts.append(f"CL:{cl}")
            lines.append("\t".join(pg_parts))

        return "\n".join(lines) + "\n"

    @staticmethod
    def _iter_alignment_lines(run: WrittenGenomicRun) -> Iterable[str]:
        """Yield one SAM alignment text line per read in ``run``.

        Field handling per HANDOFF §2.4:
        - QNAME / RNAME / CIGAR: ``"*"`` sentinel preserved.
        - FLAG / MAPQ / TLEN: decimal ints (signed for TLEN,
          unsigned otherwise).
        - POS / PNEXT: decimal ints; ``mate_position == -1`` is
          mapped to SAM's ``0`` per Binding Decision §138.
        - RNEXT: collapsed to ``=`` when equal to RNAME per Binding
          Decision §136 (writer-side reverse of M87's expansion).
        - SEQ / QUAL: ASCII bytes from the concatenated
          sequences/qualities buffers, sliced by
          ``offsets[i]:offsets[i]+lengths[i]``. Empty slice -> ``"*"``.
        """
        seq_buf = bytes(run.sequences)
        qual_buf = bytes(run.qualities)

        n = len(run.read_names)
        for i in range(n):
            qname = run.read_names[i] or "*"
            flag = int(run.flags[i])
            rname = run.chromosomes[i] or "*"
            pos = int(run.positions[i])
            mapq = int(run.mapping_qualities[i])
            cigar = run.cigars[i] or "*"

            # RNEXT collapse (§136).
            mate_chrom = run.mate_chromosomes[i] or "*"
            if mate_chrom == rname and rname != "*":
                rnext = "="
            else:
                rnext = mate_chrom

            # PNEXT mapping (§138).
            mate_pos = int(run.mate_positions[i])
            pnext = 0 if mate_pos < 0 else mate_pos

            tlen = int(run.template_lengths[i])

            offset = int(run.offsets[i])
            length = int(run.lengths[i])
            if length == 0:
                seq = "*"
                qual = "*"
            else:
                seq_bytes = seq_buf[offset:offset + length]
                qual_bytes = qual_buf[offset:offset + length]
                seq = seq_bytes.decode("ascii")
                # M87's reader produces an all-0xff buffer when the
                # source SAM had QUAL '*' but a non-empty SEQ. Map
                # that back to SAM's '*' on write so the round trip
                # canonicalises to the source convention.
                if qual_bytes and all(b == 0xff for b in qual_bytes):
                    qual = "*"
                else:
                    # qual stored as ASCII Phred+33 already (see
                    # module docstring). Just decode latin-1 to keep
                    # the bytes round-tripping when any value > 127
                    # ever sneaks through; in practice samtools
                    # rejects QUAL > '~' (0x7e).
                    qual = qual_bytes.decode("latin-1")

            yield (
                f"{qname}\t{flag}\t{rname}\t{pos}\t{mapq}\t{cigar}\t"
                f"{rnext}\t{pnext}\t{tlen}\t{seq}\t{qual}\n"
            )

    # ------------------------------------------------------------------
    # samtools subprocess invocation
    # ------------------------------------------------------------------

    def _invoke_samtools(self, sam_text: str, *, sort: bool) -> None:
        """Pipe ``sam_text`` through samtools to produce the BAM file.

        Subclasses (CramWriter) override this to inject reference and
        format flags.
        """
        cmd_view, cmd_sort = self._build_samtools_commands(sort=sort)

        if cmd_sort is None:
            # Single-stage: samtools view -bS -o <path> -
            self._run_pipeline([cmd_view], sam_text)
        else:
            # Two-stage: view -bS -  | sort -O bam -o <path>
            self._run_pipeline([cmd_view, cmd_sort], sam_text)

    def _build_samtools_commands(
        self, *, sort: bool,
    ) -> tuple[list[str], list[str] | None]:
        """Return (view-cmd, sort-cmd-or-None) for the BAM pipeline.

        Subclasses override to swap in CRAM flags.
        """
        if sort:
            view = ["samtools", "view", "-bS", "-"]
            sort_cmd = ["samtools", "sort", "-O", "bam", "-o",
                        str(self._path), "-"]
            return view, sort_cmd
        else:
            view = ["samtools", "view", "-bS", "-o",
                    str(self._path), "-"]
            return view, None

    @staticmethod
    def _run_pipeline(commands: list[list[str]], stdin_text: str) -> None:
        """Run a 1- or 2-stage samtools pipeline; raise on non-zero exit."""
        if len(commands) == 1:
            proc = subprocess.run(
                commands[0],
                input=stdin_text.encode("ascii"),
                capture_output=True,
                timeout=120,
            )
            if proc.returncode != 0:
                stderr = (proc.stderr or b"").decode("utf-8",
                                                    errors="replace")
                raise RuntimeError(
                    f"samtools exited {proc.returncode}: "
                    f"{stderr.strip()[:500]}"
                )
            return

        # Two-stage pipeline: stage[0].stdout -> stage[1].stdin.
        first = subprocess.Popen(
            commands[0],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        second = subprocess.Popen(
            commands[1],
            stdin=first.stdout,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Allow first to receive SIGPIPE if second exits.
        if first.stdout is not None:
            first.stdout.close()

        try:
            assert first.stdin is not None
            try:
                first.stdin.write(stdin_text.encode("ascii"))
            finally:
                first.stdin.close()
            second_out, second_err = second.communicate(timeout=120)
            first.wait(timeout=30)
        except subprocess.TimeoutExpired:
            first.kill()
            second.kill()
            raise

        first_err = first.stderr.read() if first.stderr else b""
        if first.stderr is not None:
            first.stderr.close()

        if first.returncode != 0:
            err = first_err.decode("utf-8", errors="replace")
            raise RuntimeError(
                f"samtools (stage 1, {commands[0][:3]}) exited "
                f"{first.returncode}: {err.strip()[:500]}"
            )
        if second.returncode != 0:
            err = second_err.decode("utf-8", errors="replace")
            raise RuntimeError(
                f"samtools (stage 2, {commands[1][:3]}) exited "
                f"{second.returncode}: {err.strip()[:500]}"
            )
