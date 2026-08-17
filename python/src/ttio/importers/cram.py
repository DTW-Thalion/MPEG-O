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


from ..io.progress import ProgressSinkLike, _fire
from .bam import PROGRESS_INTERVAL_READS  # noqa: F401  re-export-friendly


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
        """Configure the reader with a CRAM file and its reference FASTA.

        Parameters
        ----------
        path : str or os.PathLike
            Filesystem path to a CRAM file.
        reference_fasta : str or os.PathLike
            Filesystem path to the reference FASTA the CRAM was aligned
            against. Required — CRAM cannot be decoded without it.
            samtools auto-builds a ``.fai`` index alongside the FASTA on
            first use if one isn't already present.
        """
        super().__init__(path)
        self._reference_fasta = Path(reference_fasta)

    @property
    def reference_fasta(self) -> Path:
        """Return the reference-FASTA path.

        Returns
        -------
        pathlib.Path
            The reference path supplied at construction, unchanged.
        """
        return self._reference_fasta

    def _view_cmd(self, region: str | None) -> list[str]:
        if not self._reference_fasta.exists():
            raise FileNotFoundError(
                f"CRAM reference FASTA not found: {self._reference_fasta}")
        cmd = ["samtools", "view", "-h", "--reference", str(self._reference_fasta),
               str(self._path)]
        if region is not None:
            cmd.append(region)
        return cmd
