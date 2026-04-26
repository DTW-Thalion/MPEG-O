"""GenomicRun — lazy view over /study/genomic_runs/<name>/.

Materialises :class:`ttio.aligned_read.AlignedRead` instances on demand
from the signal channels stored under ``signal_channels/``.  The
:class:`ttio.genomic_index.GenomicIndex` is loaded eagerly at open time
for cheap filtering and offset lookups.

Genomic analogue of :class:`ttio.acquisition_run.AcquisitionRun`.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator, TYPE_CHECKING

from .aligned_read import AlignedRead
from .enums import AcquisitionMode
from .genomic_index import GenomicIndex

if TYPE_CHECKING:
    from .providers.base import StorageGroup


def _wrap_hdf5_group(obj: object) -> "StorageGroup":
    """Adapt an h5py.Group to a StorageGroup; pass-through for StorageGroup."""
    from .providers.base import StorageGroup as _SG
    if isinstance(obj, _SG):
        return obj
    from .providers.hdf5 import _Group as _Hdf5Group
    return _Hdf5Group(obj)  # type: ignore[arg-type]


@dataclass(slots=True)
class GenomicRun:
    """Lazy view over one /study/genomic_runs/<name>/ group.

    The :class:`GenomicIndex` and run-level attributes are loaded eagerly
    at :meth:`open` time so that ``len(gr)`` and region filtering are
    cheap.  Signal channel datasets are opened lazily and cached on first
    access.  Compound datasets (``cigars``, ``read_names``, ``mate_info``)
    are read whole-dataset once and cached.
    """

    name: str
    acquisition_mode: AcquisitionMode
    modality: str
    reference_uri: str
    platform: str
    sample_name: str
    index: GenomicIndex
    group: "StorageGroup"
    channel_names: list[str]  # populated for introspection / future tooling; not read by __getitem__

    _signal_cache: dict = field(default_factory=dict, repr=False, compare=False)
    _compound_cache: dict[str, list[dict]] = field(default_factory=dict, repr=False, compare=False)
    # M86: lazy whole-channel decode cache for byte channels whose
    # @compression attribute names a TTIO codec (rANS / BASE_PACK).
    # Codec output is byte-stream non-sliceable, so the whole channel
    # is decoded once on first access and the decoded buffer is
    # sliced from memory thereafter (Binding Decision §89). Cache
    # lifetime is the GenomicRun instance — re-opening the file
    # incurs the decode cost again (Gotcha §101).
    _decoded_byte_channels: dict[str, bytes] = field(
        default_factory=dict, repr=False, compare=False,
    )

    # ------------------------------------------------------------------
    # Sequence protocol
    # ------------------------------------------------------------------

    def __len__(self) -> int:
        return self.index.count

    def __iter__(self) -> Iterator[AlignedRead]:
        for i in range(len(self)):
            yield self[i]

    def __getitem__(self, i: int) -> AlignedRead:
        if i < 0:
            i += len(self)
        if not 0 <= i < len(self):
            raise IndexError(
                f"read index {i} out of range [0, {len(self)})"
            )

        offset = int(self.index.offsets[i])
        length = int(self.index.lengths[i])

        # Per-read scalar fields come straight from the index.
        position = int(self.index.positions[i])
        mapq = int(self.index.mapping_qualities[i])
        flag = int(self.index.flags[i])
        chrom = self.index.chromosomes[i]

        # Sequence and qualities — read a slice of the per-base channels.
        # M86: routed through _byte_channel_slice so that channels
        # written with a TTIO codec override (@compression > 0) are
        # decoded transparently before slicing.
        seq_bytes = self._byte_channel_slice("sequences", offset, length)
        sequence = seq_bytes.decode("ascii")
        qualities = self._byte_channel_slice("qualities", offset, length)

        # Compound channels — load whole-dataset once and cache.
        # read_compound_dataset already decodes VL bytes to str.
        cigars = self._compound("cigars")
        cigar = cigars[i]["value"]

        names = self._compound("read_names")
        read_name = names[i]["value"]

        mates = self._compound("mate_info")
        mate = mates[i]
        mate_chromosome = mate["chrom"]
        mate_position = int(mate["pos"])
        template_length = int(mate["tlen"])

        return AlignedRead(
            read_name=read_name,
            chromosome=chrom,
            position=position,
            mapping_quality=mapq,
            cigar=cigar,
            sequence=sequence,
            qualities=qualities,
            flags=flag,
            mate_chromosome=mate_chromosome,
            mate_position=mate_position,
            template_length=template_length,
        )

    # ------------------------------------------------------------------
    # Region query
    # ------------------------------------------------------------------

    def reads_in_region(
        self, chromosome: str, start: int, end: int
    ) -> list[AlignedRead]:
        """Return reads on ``chromosome`` whose mapping position is in ``[start, end)``.

        Note: filters by mapping position only, not by read end coordinate.
        A read whose start lies outside the window but extends into it
        will NOT be returned. Use SAM-style overlap semantics in a future
        enhancement if needed.
        """
        return [
            self[i]
            for i in self.index.indices_for_region(chromosome, start, end)
        ]

    # ------------------------------------------------------------------
    # Factory
    # ------------------------------------------------------------------

    @classmethod
    def open(cls, group, name: str) -> "GenomicRun":
        """Open an existing genomic_runs/<name>/ group.

        Mirrors :meth:`ttio.acquisition_run.AcquisitionRun.open`: the
        caller resolves the child group before calling this classmethod.
        The genomic index and run-level attributes are loaded eagerly;
        signal channel datasets remain closed until first access.
        """
        from . import _hdf5_io as io

        sgroup = _wrap_hdf5_group(group)

        # Eager: load the genomic index.
        idx_group = sgroup.open_group("genomic_index")
        index = GenomicIndex.read(idx_group)

        # Eager: list signal channel names.
        sig = sgroup.open_group("signal_channels")
        channel_names = list(sig.child_names())

        # Eager: run-level attributes written by _write_genomic_run.
        acq_mode_raw = io.read_int_attr(sgroup, "acquisition_mode")
        modality = io.read_string_attr(sgroup, "modality") or ""
        reference_uri = io.read_string_attr(sgroup, "reference_uri") or ""
        platform = io.read_string_attr(sgroup, "platform") or ""
        sample_name = io.read_string_attr(sgroup, "sample_name") or ""

        return cls(
            name=name,
            acquisition_mode=AcquisitionMode(int(acq_mode_raw)),
            modality=modality,
            reference_uri=reference_uri,
            platform=platform,
            sample_name=sample_name,
            index=index,
            group=sgroup,
            channel_names=channel_names,
        )

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _signal_dataset(self, name: str):
        """Open a primitive signal-channel dataset and cache the handle."""
        if name not in self._signal_cache:
            sig = self.group.open_group("signal_channels")
            self._signal_cache[name] = sig.open_dataset(name)
        return self._signal_cache[name]

    def _byte_channel_slice(self, name: str, offset: int, count: int) -> bytes:
        """Return bytes ``[offset, offset+count)`` for a uint8 byte channel.

        M86 dispatch: for codec-compressed channels (``@compression > 0``)
        the whole channel is decoded once on first access, the decoded
        buffer is cached on this :class:`GenomicRun` instance, and
        subsequent slices are taken from the cached bytes. For
        uncompressed channels (no attribute or value 0) the existing
        per-slice :meth:`StorageDataset.read` path is used unchanged
        — no whole-channel materialisation, no behaviour change vs M82.
        """
        cached = self._decoded_byte_channels.get(name)
        if cached is not None:
            return cached[offset:offset + count]

        ds = self._signal_dataset(name)
        from . import _hdf5_io as io
        codec_id = io.read_int_attr(ds, "compression", default=0) or 0
        if codec_id == 0:
            return bytes(ds.read(offset=offset, count=count))

        # Compressed: read all bytes, decode, cache for subsequent slices.
        from .enums import Compression
        all_bytes = bytes(ds.read(offset=0, count=int(ds.length)))
        if codec_id == int(Compression.RANS_ORDER0):
            from .codecs.rans import decode as _dec
            decoded = _dec(all_bytes)
        elif codec_id == int(Compression.RANS_ORDER1):
            from .codecs.rans import decode as _dec
            decoded = _dec(all_bytes)
        elif codec_id == int(Compression.BASE_PACK):
            from .codecs.base_pack import decode as _dec
            decoded = _dec(all_bytes)
        elif codec_id == int(Compression.QUALITY_BINNED):
            # Phase D: Illumina-8 Phred bin decode (lossy on encode;
            # decode is deterministic from the wire stream).
            from .codecs.quality import decode as _dec
            decoded = _dec(all_bytes)
        else:
            raise ValueError(
                f"signal_channel '{name}': @compression={codec_id} "
                "is not a supported TTIO codec id"
            )
        self._decoded_byte_channels[name] = decoded
        return decoded[offset:offset + count]

    def _compound(self, name: str) -> list[dict]:
        """Read a compound dataset whole and cache it.

        ``read_compound_dataset`` already decodes VL bytes to ``str``, so
        callers never need to check ``isinstance(v, bytes)``.
        """
        if name not in self._compound_cache:
            from . import _hdf5_io as io
            sig = self.group.open_group("signal_channels")
            self._compound_cache[name] = io.read_compound_dataset(sig, name)
        return self._compound_cache[name]
