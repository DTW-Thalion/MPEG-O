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

import numpy as np

from typing import Any

from .aligned_read import AlignedRead
from .enums import AcquisitionMode, Compression, Precision
from .genomic_index import GenomicIndex
from . import _hdf5_io as io

# Hoist codec imports out of per-read accessor hot paths. Without
# these, every per-read lazy decode call invokes
# ``importlib._handle_fromlist`` — measured at ~6% of decode wall
# (~9s on chr22) when these were inside the per-read methods.
from .codecs import name_tokenizer as _name_tok
from .codecs.rans import decode as _rans_decode
from .codecs.name_tokenizer import _varint_decode as _name_tok_varint_decode


# M86 Phase B: per-integer-channel dtype lookup, mirroring the
# write side (see ``_hdf5_io._INTEGER_CHANNEL_DTYPES``). Determined
# by channel name (Binding Decision §115), not by an on-disk
# attribute, so the reader recovers the original integer dtype
# from the codec-decoded byte buffer without touching extra
# metadata.
_INTEGER_CHANNEL_DTYPES = {
    "positions": "<i8",
    "flags": "<u4",
    "mapping_qualities": "<u1",
}

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
    # M86 Phase E: lazy decode cache for the read_names channel when
    # it carries a NAME_TOKENIZED codec override. Held as a
    # ``list[str]`` because the codec returns the decoded names
    # already split into per-read entries (different value type from
    # ``_decoded_byte_channels``, which holds raw concatenated
    # bytes). Per Binding Decision §114 the two caches are kept
    # separate. ``None`` until first access; when populated, the
    # whole list is materialised in memory (a few hundred MB for
    # 10M reads — acceptable for typical genomic workloads, see
    # Gotcha §125).
    _decoded_read_names: list[str] | None = field(
        default=None, repr=False, compare=False,
    )
    # M86 Phase C: lazy decode cache for the cigars channel when it
    # carries a TTIO codec override (RANS_ORDER0 / RANS_ORDER1 /
    # NAME_TOKENIZED). Held as a ``list[str]`` because all three
    # codec paths produce per-read string entries — the rANS path
    # walks varint-length-prefix entries inside the decoded byte
    # buffer, and NAME_TOKENIZED returns ``list[str]`` directly.
    # Per Binding Decision §123 (Option A from §2.3) this cache is
    # **separate** from ``_decoded_read_names`` — the lower-risk
    # choice that does not touch shipped Phase E code. A future
    # generalisation (Option B) could fold both into a
    # ``dict[str, list[str]]`` if a third list-of-strings channel
    # appears. Cache lifetime is the GenomicRun instance (Gotcha
    # §138).
    _decoded_cigars: list[str] | None = field(
        default=None, repr=False, compare=False,
    )
    # M86 Phase B: lazy whole-channel decode cache for integer
    # channels (positions, flags, mapping_qualities) whose
    # ``@compression`` attribute names a TTIO codec (currently
    # rANS only — Binding Decision §117). Held as a
    # ``dict[str, np.ndarray]`` because each entry is a typed
    # numpy array, not raw bytes. Per Binding Decision §116 this
    # cache is **separate** from ``_decoded_byte_channels`` (raw
    # bytes) and ``_decoded_read_names`` (decoded list) — the
    # value types differ and conflating would force a union
    # type and unnecessary type checks in every read path.
    _decoded_int_channels: dict[str, "np.ndarray"] = field(
        default_factory=dict, repr=False, compare=False,
    )
    # M86 Phase F: combined per-field cache for the mate_info subgroup
    # layout (Binding Decision §129, Gotcha §144). Held as a single
    # ``dict[str, Any]`` keyed by field name (``"chrom"`` →
    # list[str]; ``"pos"`` → np.ndarray int64; ``"tlen"`` →
    # np.ndarray int32) because the three fields have three different
    # value types — a typed-per-field cache would force a union or
    # three separate fields. Used only for the Phase F subgroup
    # layout; the M82 compound layout still uses the existing
    # ``_compound_cache`` via :meth:`_compound`. ``_mate_<field>_at``
    # populates the corresponding key on first access.
    _decoded_mate_info: dict[str, Any] = field(
        default_factory=dict, repr=False, compare=False,
    )

    # Cached result of `_mate_info_is_subgroup()`. Without this, the
    # method does an HDF5 link-type probe on every call, and the
    # per-read decode path calls it 3x per read — at chr22 scale
    # (1.77M reads) that's 5.3M redundant probes resolving to the
    # same answer, dominating decode wall-time. None = not yet
    # computed; True/False = cached result.
    _mate_info_subgroup_cached: "bool | None" = field(
        default=None, repr=False, compare=False,
    )

    # ------------------------------------------------------------------
    # Sequence protocol
    # ------------------------------------------------------------------

    def __len__(self) -> int:
        return self.index.count

    def __iter__(self) -> Iterator[AlignedRead]:
        for i in range(len(self)):
            yield self[i]

    def provenance_chain(self) -> "list":
        """Return per-run provenance records in insertion order.

        Closes the M91 read-side gap: until Phase 1 the lazy
        ``GenomicRun`` view didn't expose provenance, so cross-
        modality queries had to fall back to the ``sample_name``
        attribute. Now both run types share the same accessor.

        Reads from the ``<run>/provenance/steps`` compound dataset
        written by :func:`spectral_dataset._write_genomic_run`.
        Returns ``[]`` for runs that carry no provenance.
        """
        # Use the h5py-native path through the StorageGroup wrapper.
        # The provenance compound layout is identical to the MS path
        # (see acquisition_run.AcquisitionRun.provenance) and is
        # decoded by the same helper.
        from .acquisition_run import (
            _decode_provenance_compound, _native_h5py,
        )
        try:
            h5group = _native_h5py(self.group)
        except Exception:
            return []
        if h5group is None:
            return []
        if "provenance" in h5group and "steps" in h5group["provenance"]:
            return _decode_provenance_compound(
                h5group["provenance"], "steps",
            )
        return []

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

        # Compound / codec-lifted channels — dispatch on dataset
        # shape (M86 Phases C and E). The compound path delegates
        # to ``_compound`` (whole-dataset cached), the codec path
        # decodes once and caches ``list[str]``.
        cigar = self._cigar_at(i)

        read_name = self._read_name_at(i)

        # M86 Phase F: dispatch on HDF5 link type (compound dataset =
        # M82 path; subgroup = Phase F per-field path). The three
        # helpers each open the bare ``mate_info`` link, detect the
        # layout, and route to either the existing ``_compound``
        # cache (M82) or the per-field codec/natural-dtype dispatch
        # (Phase F).
        mate_chromosome = self._mate_chrom_at(i)
        mate_position = self._mate_pos_at(i)
        template_length = self._mate_tlen_at(i)

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
        codec_id = io.read_int_attr(ds, "compression", default=0) or 0
        if codec_id == 0:
            return bytes(ds.read(offset=offset, count=count))

        # Compressed: read all bytes, decode, cache for subsequent slices.
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
        elif codec_id == int(Compression.REF_DIFF):
            # M93 v1.2: REF_DIFF is context-aware. The sequences blob
            # carries a codec header naming the reference URI + md5; we
            # resolve via :class:`ReferenceResolver` (embedded → external
            # → RefMissingError per Q5c = A) and feed the per-read CIGARs
            # + positions to the decoder. The decoder returns
            # ``list[bytes]`` (one per read); we concat into the M82
            # contract: a flat uint8 byte stream the same length as
            # ``sum(lengths)``.
            decoded = self._decode_ref_diff_sequences(all_bytes)
        elif codec_id == int(Compression.FQZCOMP_NX16):
            # M94 v1.2: FQZCOMP_NX16 lossless quality codec. The codec
            # wire format carries read_lengths inside its sidecar; the
            # revcomp_flags must be derived from run.flags & 16 (SAM
            # REVERSE) to reproduce the encoder's context trajectory.
            decoded = self._decode_fqzcomp_nx16_qualities(all_bytes)
        elif codec_id == int(Compression.FQZCOMP_NX16_Z):
            # M94.Z v1.2: CRAM-mimic FQZCOMP_NX16 (rANS-Nx16). Same
            # plumbing as v1: codec carries read_lengths inside its
            # sidecar; revcomp_flags come from run.flags & 16. Different
            # on-wire format (magic ``M94Z``).
            decoded = self._decode_fqzcomp_nx16_z_qualities(all_bytes)
        else:
            raise ValueError(
                f"signal_channel '{name}': @compression={codec_id} "
                "is not a supported TTIO codec id"
            )
        self._decoded_byte_channels[name] = decoded
        return decoded[offset:offset + count]

    def _decode_ref_diff_sequences(self, encoded: bytes) -> bytes:
        """Decode the ``sequences`` channel encoded with the M93 REF_DIFF codec.

        Returns the concatenated per-read sequence bytes — same shape and
        dtype contract as the M82 ``sequences`` channel
        (``uint8`` 1-D byte stream of total length ``sum(lengths)``).

        Raises:
            RefMissingError: when the reference can't be resolved.
        """
        from .codecs.ref_diff import (
            decode as _ref_diff_decode,
            unpack_codec_header as _unpack_header,
        )
        from .genomic.reference_resolver import ReferenceResolver
        from .acquisition_run import _native_h5py

        # Pull the URI + md5 out of the codec header so the resolver
        # can verify against /study/references/<uri>/.
        header, _ = _unpack_header(encoded)

        # ReferenceResolver wants a native h5py.File handle; the writer
        # always embeds at /study/references/<uri>/ in the same file.
        try:
            h5_grp = _native_h5py(self.group)
        except TypeError as exc:
            raise RuntimeError(
                "REF_DIFF decode requires an HDF5-backed dataset; "
                "non-HDF5 storage providers are not yet supported."
            ) from exc
        h5_file = h5_grp.file
        resolver = ReferenceResolver(h5_file)

        # Single-chromosome runs only (v1.2 first pass — write side
        # rejects multi-chrom too).
        unique_chroms = set(self.index.chromosomes)
        if len(unique_chroms) == 0:
            chrom = ""  # empty run; resolver will likely fail
        elif len(unique_chroms) > 1:
            raise RuntimeError(
                "REF_DIFF v1.2 first pass supports single-chromosome "
                f"runs only; this run carries {sorted(unique_chroms)}. "
                "Multi-chromosome support is an M93.X follow-up."
            )
        else:
            chrom = next(iter(unique_chroms))

        chrom_seq = resolver.resolve(
            uri=header.reference_uri,
            expected_md5=header.reference_md5,
            chromosome=chrom,
        )

        # Gather per-read positions + cigars for the slice walk.
        positions = [int(p) for p in self.index.positions]
        cigars = self._all_cigars()

        per_read = _ref_diff_decode(encoded, cigars, positions, chrom_seq)
        return b"".join(per_read)

    def _decode_fqzcomp_nx16_qualities(self, encoded: bytes) -> bytes:
        """Decode the ``qualities`` channel encoded with the M94 FQZCOMP_NX16 codec.

        Returns the concatenated per-read quality byte stream — same
        shape and dtype contract as the M82 ``qualities`` channel
        (``uint8`` 1-D byte stream of total length ``sum(lengths)``).

        The codec carries ``read_lengths`` inside its own header; we
        recover ``revcomp_flags`` from ``run.flags & 16`` (SAM REVERSE
        bit) to reproduce the encoder's context trajectory.
        """
        from .codecs.fqzcomp_nx16 import decode_with_metadata as _fqz_decode

        SAM_REVERSE = 16
        flags = self.index.flags  # numpy uint32 array
        revcomp_flags = [
            1 if (int(f) & SAM_REVERSE) else 0 for f in flags
        ]
        qualities, _, _ = _fqz_decode(encoded, revcomp_flags=revcomp_flags)
        return qualities

    def _decode_fqzcomp_nx16_z_qualities(self, encoded: bytes) -> bytes:
        """Decode the ``qualities`` channel encoded with the M94.Z codec.

        Drop-in parallel to :meth:`_decode_fqzcomp_nx16_qualities` — same
        signature, same ``revcomp_flags`` derivation; only the underlying
        codec module differs (``fqzcomp_nx16_z`` instead of v1's
        ``fqzcomp_nx16``).
        """
        from .codecs.fqzcomp_nx16_z import (
            decode_with_metadata as _fqz_z_decode,
        )

        SAM_REVERSE = 16
        flags = self.index.flags  # numpy uint32 array
        revcomp_flags = [
            1 if (int(f) & SAM_REVERSE) else 0 for f in flags
        ]
        qualities, _, _ = _fqz_z_decode(encoded, revcomp_flags=revcomp_flags)
        return qualities

    def _all_cigars(self) -> list[str]:
        """Return the full list of CIGAR strings for this run.

        Honours the M86 Phase C codec dispatch on the ``cigars``
        channel (RANS / NAME_TOKENIZED override → uint8 dataset; no
        override → M82 compound dataset). Caches the result on
        ``self._decoded_cigars`` so subsequent ``_cigar_at`` calls
        hit the cache.
        """
        if self._decoded_cigars is not None:
            return self._decoded_cigars
        # Trigger the existing per-read decode path once; the helper
        # populates ``self._decoded_cigars`` for the rANS / tokenised
        # paths. The compound (M82) path doesn't populate the field,
        # so fall back to a manual walk in that case.
        _ = self._cigar_at(0) if len(self) > 0 else None
        if self._decoded_cigars is not None:
            return self._decoded_cigars
        # M82 compound layout — gather from the compound cache.
        cigars = self._compound("cigars")
        out = [c["value"] for c in cigars]
        self._decoded_cigars = out
        return out

    def _int_channel_array(self, name: str) -> "np.ndarray":
        """Return the full integer array for ``name``, lazily decoded.

        M86 Phase B dispatch: for codec-compressed integer channels
        (``@compression`` names a TTIO rANS id) the entire dataset is
        read once on first access, decoded through the codec, and
        re-interpreted as the channel's natural integer dtype
        (Binding Decision §115). The resulting numpy array is cached
        on this :class:`GenomicRun` instance per Binding Decision
        §116 (separate from the byte and read-names caches because
        the value type is different). For uncompressed channels
        (no ``@compression`` attribute or value 0) the dataset is
        read directly and re-interpreted via the same channel-name
        dtype lookup.

        Per Binding Decision §119, this helper is **callable but not
        currently called** by :meth:`__getitem__`, which still uses
        ``self.index.{positions,mapping_qualities,flags}`` for per-
        read integer access. Phase B is primarily a write-side
        file-size optimisation; the read-path dispatch is wired here
        for round-trip correctness and for any future reader that
        prefers ``signal_channels/`` over ``genomic_index/``.
        """
        cached = self._decoded_int_channels.get(name)
        if cached is not None:
            return cached

        dtype_str = _INTEGER_CHANNEL_DTYPES.get(name)
        if dtype_str is None:
            raise ValueError(
                f"_int_channel_array: unknown integer channel "
                f"name {name!r}"
            )

        ds = self._signal_dataset(name)
        codec_id = io.read_int_attr(ds, "compression", default=0) or 0

        if codec_id == 0:
            # Uncompressed: read the dataset directly. The dataset
            # is stored at its native integer precision, so the
            # provider's ``read`` returns a typed buffer; we
            # re-interpret as the canonical LE dtype to keep the
            # value type uniform with the codec path.
            raw = bytes(np.asarray(ds.read(offset=0, count=int(ds.length))).tobytes())
            arr = np.frombuffer(raw, dtype=dtype_str)
            self._decoded_int_channels[name] = arr
            return arr

        if codec_id in (
            int(Compression.RANS_ORDER0),
            int(Compression.RANS_ORDER1),
        ):
            from .codecs.rans import decode as _dec
            all_bytes = bytes(ds.read(offset=0, count=int(ds.length)))
            decoded_bytes = _dec(all_bytes)
            arr = np.frombuffer(decoded_bytes, dtype=dtype_str)
            self._decoded_int_channels[name] = arr
            return arr

        if codec_id == int(Compression.DELTA_RANS_ORDER0):
            from .codecs.delta_rans import decode as _dec
            all_bytes = bytes(ds.read(offset=0, count=int(ds.length)))
            decoded_bytes = _dec(all_bytes)
            arr = np.frombuffer(decoded_bytes, dtype=dtype_str)
            self._decoded_int_channels[name] = arr
            return arr

        raise ValueError(
            f"signal_channel '{name}': @compression={codec_id} "
            "is not a supported TTIO codec id for an integer channel "
            "(RANS_ORDER0 = 4, RANS_ORDER1 = 5, DELTA_RANS_ORDER0 = 11)"
        )

    def _compound(self, name: str) -> list[dict]:
        """Read a compound dataset whole and cache it.

        ``read_compound_dataset`` already decodes VL bytes to ``str``, so
        callers never need to check ``isinstance(v, bytes)``.
        """
        if name not in self._compound_cache:
            sig = self.group.open_group("signal_channels")
            self._compound_cache[name] = io.read_compound_dataset(sig, name)
        return self._compound_cache[name]

    def _read_name_at(self, i: int) -> str:
        """Return the read name at index ``i``, dispatching on shape.

        M86 Phase E: read_names has two on-disk layouts (Binding
        Decisions §111, §112):

        - **M82 compound** (no override): VL_STRING-in-compound
          dataset, read whole-and-cache via :meth:`_compound`.
        - **NAME_TOKENIZED** (override active): flat 1-D uint8
          dataset, decoded once on first access and cached as a
          ``list[str]`` on this :class:`GenomicRun` instance per
          Binding Decision §114.

        Dispatch is on dataset shape — a 1-D uint8 dataset routes
        through the codec path; anything else falls through to the
        compound path. The :attr:`_decoded_read_names` cache holds
        the entire decoded list across calls.
        """
        cached = self._decoded_read_names
        if cached is not None:
            return cached[i]

        sig = self.group.open_group("signal_channels")
        ds = sig.open_dataset("read_names")

        # Shape dispatch: precision == UINT8 → codec path; otherwise
        # the dataset is the M82 compound (precision is None for
        # compound datasets, since they have no scalar Precision).
        if ds.precision == Precision.UINT8:
            codec_id = io.read_int_attr(ds, "compression", default=0) or 0
            if codec_id == int(Compression.NAME_TOKENIZED):
                all_bytes = bytes(ds.read(offset=0, count=int(ds.length)))
                self._decoded_read_names = _name_tok.decode(all_bytes)
                return self._decoded_read_names[i]
            raise ValueError(
                f"signal_channel 'read_names': @compression={codec_id} "
                "is not a supported TTIO codec id for the read_names "
                "channel (only NAME_TOKENIZED = 8 is recognised)"
            )

        # Compound path (M82, no override).
        names = self._compound("read_names")
        return names[i]["value"]

    def _cigar_at(self, i: int) -> str:
        """Return the cigar string at index ``i``, dispatching on shape.

        M86 Phase C: cigars has two on-disk layouts (Binding
        Decisions §120-§123):

        - **M82 compound** (no override): VL_STRING-in-compound
          dataset, read whole-and-cache via :meth:`_compound`.
        - **TTIO codec** (override active): flat 1-D uint8
          dataset, decoded once on first access and cached as a
          ``list[str]`` on this :class:`GenomicRun` instance per
          Binding Decision §123. Three codec ids are recognised:

          * ``RANS_ORDER0`` (4) and ``RANS_ORDER1`` (5): the
            decoded byte buffer is a length-prefix-concat sequence
            (``varint(len) + bytes`` per CIGAR — §2.5 of the
            Phase C plan / format-spec §10.6 extended). Walk the
            buffer to reconstruct the ``list[str]``.
          * ``NAME_TOKENIZED`` (8): pass the bytes through the
            codec's ``decode(bytes) -> list[str]`` API directly.

        Dispatch is on dataset shape — a 1-D uint8 dataset routes
        through the codec path; anything else (compound) falls
        through to the M82 path. The :attr:`_decoded_cigars` cache
        holds the entire decoded list across calls.
        """
        cached = self._decoded_cigars
        if cached is not None:
            return cached[i]

        sig = self.group.open_group("signal_channels")
        ds = sig.open_dataset("cigars")

        if ds.precision == Precision.UINT8:
            codec_id = io.read_int_attr(ds, "compression", default=0) or 0
            all_bytes = bytes(ds.read(offset=0, count=int(ds.length)))
            if codec_id in (
                int(Compression.RANS_ORDER0),
                int(Compression.RANS_ORDER1),
            ):
                decoded = _rans_decode(all_bytes)
                _vd = _name_tok_varint_decode
                # Walk the length-prefix-concat byte stream — the
                # mirror of the writer's serialisation contract
                # (§2.5). Each entry is varint(len) + len bytes
                # of ASCII payload.
                out: list[str] = []
                offset = 0
                n = len(decoded)
                while offset < n:
                    length, offset = _vd(decoded, offset)
                    if offset + length > n:
                        raise ValueError(
                            "cigars rANS stream: length-prefix-concat "
                            f"entry runs off end of decoded buffer "
                            f"(offset={offset}, length={length}, "
                            f"buffer_size={n})"
                        )
                    payload = decoded[offset:offset + length]
                    offset += length
                    try:
                        out.append(payload.decode("ascii"))
                    except UnicodeDecodeError as exc:
                        raise ValueError(
                            "cigars rANS stream: entry contains "
                            "non-ASCII bytes"
                        ) from exc
                self._decoded_cigars = out
                return out[i]
            if codec_id == int(Compression.NAME_TOKENIZED):
                _nt = _name_tok
                self._decoded_cigars = _nt.decode(all_bytes)
                return self._decoded_cigars[i]
            raise ValueError(
                f"signal_channel 'cigars': @compression={codec_id} "
                "is not a supported TTIO codec id for the cigars "
                "channel (only RANS_ORDER0 = 4, RANS_ORDER1 = 5, "
                "and NAME_TOKENIZED = 8 are recognised)"
            )

        # Compound path (M82, no override).
        cigars = self._compound("cigars")
        return cigars[i]["value"]

    # ------------------------------------------------------------------
    # M86 Phase F — mate_info per-field dispatch
    # ------------------------------------------------------------------

    def _mate_info_is_subgroup(self) -> bool:
        """True iff ``signal_channels/mate_info`` is a group (Phase F).

        Per Binding Decision §128 / Gotcha §141, dispatch is on HDF5
        link type, NOT on ``@compression`` attribute presence on the
        bare link. The StorageGroup protocol's ``open_group`` raises
        ``KeyError`` when the named child is a dataset (verified in
        :class:`ttio.providers.hdf5._Group.open_group`); we use that
        as the link-type query.

        Result is cached on the instance — the file structure is
        immutable for the lifetime of an open run, so the link-type
        probe only runs once.
        """
        if self._mate_info_subgroup_cached is not None:
            return self._mate_info_subgroup_cached
        sig = self.group.open_group("signal_channels")
        try:
            sig.open_group("mate_info")
            self._mate_info_subgroup_cached = True
        except KeyError:
            self._mate_info_subgroup_cached = False
        return self._mate_info_subgroup_cached

    def _decode_mate_chrom(self):
        """Lazily decode the chrom field from the Phase F subgroup.

        Populates ``_decoded_mate_info["chrom"]`` with a
        ``list[str]`` and returns it.
        """
        cached = self._decoded_mate_info.get("chrom")
        if cached is not None:
            return cached

        sig = self.group.open_group("signal_channels")
        mate_group = sig.open_group("mate_info")

        # Dispatch on dataset shape inside the subgroup. Per the
        # writer (§5.2), an overridden chrom field is a flat 1-D
        # uint8 dataset with @compression; an un-overridden chrom
        # is a compound (VL_STRING) dataset with no attribute.
        ds = mate_group.open_dataset("chrom")
        if ds.precision == Precision.UINT8:
            codec_id = io.read_int_attr(ds, "compression", default=0) or 0
            all_bytes = bytes(ds.read(offset=0, count=int(ds.length)))
            if codec_id in (
                int(Compression.RANS_ORDER0),
                int(Compression.RANS_ORDER1),
            ):
                _vd = _name_tok_varint_decode
                decoded = _rans_decode(all_bytes)
                out: list[str] = []
                offset = 0
                n = len(decoded)
                while offset < n:
                    length, offset = _vd(decoded, offset)
                    if offset + length > n:
                        raise ValueError(
                            "mate_info_chrom rANS stream: length-prefix-"
                            "concat entry runs off end of decoded buffer "
                            f"(offset={offset}, length={length}, "
                            f"buffer_size={n})"
                        )
                    payload = decoded[offset:offset + length]
                    offset += length
                    try:
                        out.append(payload.decode("ascii"))
                    except UnicodeDecodeError as exc:
                        raise ValueError(
                            "mate_info_chrom rANS stream: entry contains "
                            "non-ASCII bytes"
                        ) from exc
                self._decoded_mate_info["chrom"] = out
                return out
            if codec_id == int(Compression.NAME_TOKENIZED):
                _nt = _name_tok
                out = _nt.decode(all_bytes)
                self._decoded_mate_info["chrom"] = out
                return out
            raise ValueError(
                f"signal_channel 'mate_info/chrom': "
                f"@compression={codec_id} is not a supported TTIO codec id "
                "(only RANS_ORDER0 = 4, RANS_ORDER1 = 5, and "
                "NAME_TOKENIZED = 8 are recognised for this channel)"
            )

        # Natural dtype (compound VL_STRING) — un-overridden field
        # inside the subgroup. Read whole and extract the values.
        out = [r["value"] for r in io.read_compound_dataset(mate_group, "chrom")]
        self._decoded_mate_info["chrom"] = out
        return out

    def _decode_mate_int_field(
        self, name: str, dtype_str: str
    ) -> "np.ndarray":
        """Lazily decode a Phase F integer mate field (pos or tlen).

        Populates ``_decoded_mate_info[name]`` with a typed numpy
        array and returns it. ``name`` is the on-disk child name
        (``"pos"`` or ``"tlen"``); ``dtype_str`` is the natural
        integer dtype (``"<i8"`` or ``"<i4"``).
        """
        cached = self._decoded_mate_info.get(name)
        if cached is not None:
            return cached

        sig = self.group.open_group("signal_channels")
        mate_group = sig.open_group("mate_info")
        ds = mate_group.open_dataset(name)


        if ds.precision == Precision.UINT8:
            codec_id = io.read_int_attr(ds, "compression", default=0) or 0
            if codec_id in (
                int(Compression.RANS_ORDER0),
                int(Compression.RANS_ORDER1),
            ):
                from .codecs.rans import decode as _dec
                all_bytes = bytes(ds.read(offset=0, count=int(ds.length)))
                decoded_bytes = _dec(all_bytes)
                arr = np.frombuffer(decoded_bytes, dtype=dtype_str)
                self._decoded_mate_info[name] = arr
                return arr
            raise ValueError(
                f"signal_channel 'mate_info/{name}': "
                f"@compression={codec_id} is not a supported TTIO codec id "
                "for an integer mate field (only RANS_ORDER0 = 4 and "
                "RANS_ORDER1 = 5 are recognised)"
            )

        # Natural-dtype path — read the typed dataset directly and
        # re-interpret to the canonical LE dtype to keep the value
        # type uniform with the codec path.
        raw = bytes(np.asarray(ds.read(offset=0, count=int(ds.length))).tobytes())
        arr = np.frombuffer(raw, dtype=dtype_str)
        self._decoded_mate_info[name] = arr
        return arr

    def _mate_chrom_at(self, i: int) -> str:
        """Return the mate chromosome at index ``i``, dispatching on layout.

        M86 Phase F: ``signal_channels/mate_info`` has two on-disk
        layouts (Binding Decisions §125, §128, Gotcha §141):

        - **M82 compound** (no override): COMPOUND[n_reads] dataset
          with three fields. Read whole-and-cache via the existing
          :meth:`_compound` helper, then return the per-read entry.
        - **Phase F subgroup** (any mate_info_* override): GROUP
          containing three child datasets. Decode the chrom child
          on first access (cached in ``_decoded_mate_info["chrom"]``)
          and return entry [i].
        """
        if self._mate_info_is_subgroup():
            return self._decode_mate_chrom()[i]
        # M82 compound path.
        return self._compound("mate_info")[i]["chrom"]

    def _mate_pos_at(self, i: int) -> int:
        """Return the mate position at index ``i``, dispatching on layout."""
        if self._mate_info_is_subgroup():
            return int(self._decode_mate_int_field("pos", "<i8")[i])
        return int(self._compound("mate_info")[i]["pos"])

    def _mate_tlen_at(self, i: int) -> int:
        """Return the template length at index ``i``, dispatching on layout."""
        if self._mate_info_is_subgroup():
            return int(self._decode_mate_int_field("tlen", "<i4")[i])
        return int(self._compound("mate_info")[i]["tlen"])
