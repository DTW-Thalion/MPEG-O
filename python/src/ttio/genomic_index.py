"""GenomicIndex — parallel per-read metadata for selective access.

Genomic analogue of :class:`ttio.acquisition_run.SpectrumIndex`. Loaded
eagerly when a :class:`ttio.genomic_run.GenomicRun` opens. Arrays have
length == read_count and are small enough to hold in memory; the heavy
signal channels (sequences, qualities) remain lazy on disk.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from ttio.protocols import StorageGroup


@dataclass(slots=True)
class GenomicIndex:
    """Per-read metadata. All arrays have length == read_count."""

    offsets: np.ndarray            # uint64 — byte offset into sequence channel
    lengths: np.ndarray            # uint32 — read length in bases
    chromosomes: list[str]         # one per read
    positions: np.ndarray          # int64 — 0-based mapping position
    mapping_qualities: np.ndarray  # uint8
    flags: np.ndarray              # uint32

    @property
    def count(self) -> int:
        return int(self.offsets.shape[0])

    def indices_for_region(
        self, chromosome: str, start: int, end: int
    ) -> list[int]:
        """Return read indices on ``chromosome`` with start <= pos < end."""
        chrom_mask = np.array(
            [c == chromosome for c in self.chromosomes], dtype=bool
        )
        mask = chrom_mask & (self.positions >= start) & (self.positions < end)
        return np.where(mask)[0].tolist()

    def indices_for_unmapped(self) -> list[int]:
        """Return indices of unmapped reads (flag bit 0x4 set)."""
        return np.where(self.flags & 0x4)[0].tolist()

    def indices_for_flag(self, flag_mask: int) -> list[int]:
        """Return indices where ``(flags & flag_mask) != 0``."""
        return np.where(self.flags & flag_mask)[0].tolist()

    @classmethod
    def read(cls, idx_group: "StorageGroup") -> "GenomicIndex":
        """Load from a ``genomic_index/`` StorageGroup. Implemented in Task 6."""
        raise NotImplementedError("GenomicIndex.read is implemented in Task 6")

    def write(self, idx_group: "StorageGroup") -> None:
        """Write all columns into ``idx_group``. Implemented in Task 6."""
        raise NotImplementedError("GenomicIndex.write is implemented in Task 6")
