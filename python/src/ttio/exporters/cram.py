"""CRAM exporter — M88.

Subclasses :class:`~ttio.exporters.bam.BamWriter` and overrides the
samtools subprocess invocation to emit CRAM (reference-compressed)
output instead of BAM. Per Binding Decision §139 the reference
FASTA is a positional constructor argument; samtools needs it for
both the ``view -CS`` and the ``sort -O cram`` stages.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOCramWriter`` · Java:
``global.thalion.ttio.exporters.CramWriter``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import os
from pathlib import Path

from .bam import BamWriter


__all__ = ["CramWriter"]


class CramWriter(BamWriter):
    """Write a :class:`~ttio.written_genomic_run.WrittenGenomicRun` to CRAM.

    Parameters
    ----------
    path : str or :class:`pathlib.Path`
        Output CRAM file path. The ``.cram`` extension is honoured by
        samtools' file-format auto-detection (Gotcha §165).
    reference_fasta : str or :class:`pathlib.Path`
        Filesystem path to the reference FASTA. CRAM is reference-
        compressed; samtools requires the reference both at write
        time (to compute the deltas) and at read time (to
        reconstitute the bases).
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

    def _build_samtools_commands(
        self, *, sort: bool,
    ) -> tuple[list[str], list[str] | None]:
        """Override BamWriter to emit CRAM with --reference."""
        ref = str(self._reference_fasta)
        if sort:
            view = [
                "samtools", "view", "-CS",
                "--reference", ref,
                "-",
            ]
            sort_cmd = [
                "samtools", "sort", "-O", "cram",
                "--reference", ref,
                "-o", str(self._path), "-",
            ]
            return view, sort_cmd
        else:
            view = [
                "samtools", "view", "-CS",
                "--reference", ref,
                "-o", str(self._path), "-",
            ]
            return view, None
