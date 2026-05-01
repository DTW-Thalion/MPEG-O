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
    from .providers.base import StorageGroup


@dataclass(slots=True)
class GenomicIndex:
    """Parallel per-read arrays loaded eagerly at run open time.

    Genomic analogue of :class:`SpectrumIndex`. The arrays map 1:1 to
    the datasets under ``/study/genomic_runs/<name>/genomic_index/``
    (M82). They are small (length = read_count) and cheap to hold in
    memory; the heavy signal channels (sequences, qualities) remain
    lazy on disk.

    Parameters
    ----------
    offsets : numpy.ndarray
        ``uint64`` byte offset of each read into the ``sequences`` and
        ``qualities`` signal channels.
    lengths : numpy.ndarray
        ``uint32`` read length in bases for each read.
    chromosomes : list[str]
        Reference sequence name (e.g. ``"chr1"``) for each read.
        Variable-length strings stored as a compound VL_BYTES dataset
        on disk; held as a Python list in memory.
    positions : numpy.ndarray
        ``int64`` 0-based mapping position for each read.
    mapping_qualities : numpy.ndarray
        ``uint8`` mapping quality (Phred-scaled) for each read.
    flags : numpy.ndarray
        ``uint32`` SAM-style flags for each read. M82 uses UINT32 (not
        UINT16) to leave room for future extended flag bits beyond
        SAM's 12-bit range.

    Notes
    -----
    API status: Provisional (M82.1). Disk read/write methods are
    implemented in Task 6 of the M82.1 plan; until then they raise
    :class:`NotImplementedError`.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOGenomicIndex`` (M82.2 — to be implemented) ·
    Java: ``global.thalion.ttio.genomics.GenomicIndex`` (M82.3 — to
    be implemented).
    """

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
        # TODO(M82): chromosome lookup is O(N) Python; vectorize once an
        # interned chromosome_ids column lands (BAM/CRAM-style id table).
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
        """Load all columns from a ``genomic_index/`` StorageGroup.

        L1 (Task #82 Phase B.1, 2026-05-01): chromosomes are stored as
        a uint16 id column + compound name lookup table (sibling
        datasets ``chromosome_ids`` and ``chromosome_names``) instead
        of the M82-era ``chromosomes`` VL-string compound. The single
        compound was costing 42 MB of HDF5 fractal-heap overhead per
        chr22 .tio file (one fractal-heap block per chunk × 432 chunks).
        """
        from ttio import _hdf5_io as io

        offsets_ds = idx_group.open_dataset("offsets")
        lengths_ds = idx_group.open_dataset("lengths")
        positions_ds = idx_group.open_dataset("positions")
        mq_ds = idx_group.open_dataset("mapping_qualities")
        flags_ds = idx_group.open_dataset("flags")

        offsets = np.asarray(offsets_ds.read(), dtype=np.uint64)
        lengths = np.asarray(lengths_ds.read(), dtype=np.uint32)
        positions = np.asarray(positions_ds.read(), dtype=np.int64)
        mapping_qualities = np.asarray(mq_ds.read(), dtype=np.uint8)
        flags = np.asarray(flags_ds.read(), dtype=np.uint32)

        ids_ds = idx_group.open_dataset("chromosome_ids")
        ids = np.asarray(ids_ds.read(), dtype=np.uint16)
        name_rows = io.read_compound_dataset(idx_group, "chromosome_names")
        name_table: list[str] = []
        for row in name_rows:
            v = row["name"]
            name_table.append(v.decode("utf-8") if isinstance(v, bytes) else v)
        chromosomes = [name_table[i] for i in ids.tolist()]

        return cls(
            offsets=offsets,
            lengths=lengths,
            chromosomes=chromosomes,
            positions=positions,
            mapping_qualities=mapping_qualities,
            flags=flags,
        )

    def write(self, idx_group: "StorageGroup") -> None:
        """Write all columns into ``idx_group``.

        L1 layout: ``chromosome_ids`` (uint16) + ``chromosome_names``
        (compound, one row per unique chromosome). Encounter-order id
        assignment — first occurrence of a name gets the next unused
        id. Cross-language byte-exact contract.
        """
        from ttio import _hdf5_io as io
        from .enums import Precision

        io._write_uint64_channel(idx_group, "offsets", self.offsets, "gzip")
        io._write_uint32_channel(idx_group, "lengths", self.lengths, "gzip")
        io._write_int64_channel(idx_group, "positions", self.positions, "gzip")
        io._write_uint8_channel(
            idx_group, "mapping_qualities", self.mapping_qualities, "gzip"
        )
        io._write_uint32_channel(idx_group, "flags", self.flags, "gzip")

        name_to_id: dict[str, int] = {}
        names_in_order: list[str] = []
        ids = np.empty(len(self.chromosomes), dtype=np.uint16)
        for i, name in enumerate(self.chromosomes):
            slot = name_to_id.get(name)
            if slot is None:
                if len(names_in_order) > 65535:
                    raise ValueError(
                        "genomic_index: > 65,535 unique chromosome names; "
                        "uint16 chromosome_ids would overflow."
                    )
                slot = len(names_in_order)
                name_to_id[name] = slot
                names_in_order.append(name)
            ids[i] = slot

        ds = idx_group.create_dataset(
            "chromosome_ids", Precision.UINT16,
            length=int(ids.shape[0]),
            chunk_size=io.DEFAULT_SIGNAL_CHUNK,
            compression=io._compression_for("gzip"),
            compression_level=6,
        )
        ds.write(ids)
        io.write_compound_dataset(
            idx_group,
            "chromosome_names",
            [{"name": n} for n in names_in_order],
            [("name", io.vl_str())],
        )
