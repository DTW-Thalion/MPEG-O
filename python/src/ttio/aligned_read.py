"""AlignedRead — one aligned sequencing read.

Genomic analogue of :class:`ttio.mass_spectrum.MassSpectrum`. Frozen
value object materialised by :meth:`ttio.genomic_run.GenomicRun.__getitem__`
from the signal channel arrays under
``/study/genomic_runs/<name>/signal_channels/``.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class AlignedRead:
    """One aligned sequencing read."""

    read_name: str
    chromosome: str
    position: int
    mapping_quality: int
    cigar: str
    sequence: str
    qualities: bytes
    flags: int
    mate_chromosome: str
    mate_position: int
    template_length: int

    @property
    def is_mapped(self) -> bool:
        return not (self.flags & 0x4)

    @property
    def is_paired(self) -> bool:
        return bool(self.flags & 0x1)

    @property
    def is_reverse(self) -> bool:
        return bool(self.flags & 0x10)

    @property
    def is_secondary(self) -> bool:
        return bool(self.flags & 0x100)

    @property
    def is_supplementary(self) -> bool:
        return bool(self.flags & 0x800)

    @property
    def read_length(self) -> int:
        return len(self.sequence)
