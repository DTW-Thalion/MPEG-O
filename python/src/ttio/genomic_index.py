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


def _offsets_from_lengths(lengths: np.ndarray) -> np.ndarray:
    """Synthesize per-record byte offsets from a lengths array.

    ``offsets[i] = sum(lengths[0..i])``. Always uint64 to avoid the
    overflow cliff at >4 GB on deep WGS even when the input lengths
    array is uint32. Returns a fresh array of shape ``(n,)``; for
    empty input returns an empty uint64 array.

    v1.10 #10 (2026-05-04): canonical helper for the new on-disk
    schema where ``offsets`` is omitted from disk and computed at
    read time. Genomic + spectrum + chromatogram indexes share this
    helper.
    """
    n = int(lengths.shape[0])
    if n == 0:
        return np.zeros(0, dtype=np.uint64)
    out = np.empty(n, dtype=np.uint64)
    out[0] = 0
    if n > 1:
        # Use uint64 cumsum to avoid uint32 overflow on deep WGS.
        np.cumsum(lengths[:-1].astype(np.uint64, copy=False), out=out[1:])
    return out


def _read_offsets_from_lengths_dataset(
    idx_group: "StorageGroup",
    lengths_dtype: type = np.uint32,
) -> np.ndarray:
    """Read the ``lengths`` dataset and synthesize uint64 offsets.

    Convenience wrapper for callers that only need offsets — same as
    open + read + ``_offsets_from_lengths`` but avoids the boilerplate.
    """
    lengths = np.asarray(
        idx_group.open_dataset("lengths").read(), dtype=lengths_dtype,
    )
    return _offsets_from_lengths(lengths)


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

        Chromosomes are stored as a uint16 id column + compound name
        lookup table (sibling datasets ``chromosome_ids`` and
        ``chromosome_names``). ``offsets`` is never on disk in v1.0+
        files — it's computed from ``cumsum(lengths)`` here.
        """
        from ttio import _hdf5_io as io

        lengths_ds = idx_group.open_dataset("lengths")
        positions_ds = idx_group.open_dataset("positions")
        mq_ds = idx_group.open_dataset("mapping_qualities")
        flags_ds = idx_group.open_dataset("flags")

        lengths = np.asarray(lengths_ds.read(), dtype=np.uint32)
        offsets = _offsets_from_lengths(lengths)
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

        v1.0 layout: ``chromosome_ids`` (uint16) + ``chromosome_names``
        (compound, one row per unique chromosome). Encounter-order id
        assignment — first occurrence of a name gets the next unused
        id. Cross-language byte-exact contract.

        ``offsets`` is never written — readers derive from
        ``cumsum(lengths)``.
        """
        from ttio import _hdf5_io as io
        from .enums import Precision

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
