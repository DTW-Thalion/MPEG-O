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
#
# v1.0 reset (Phase 2c): the v1 ``name_tokenizer`` codec was removed.
# The ULEB128 varint primitives (used by the cigars rANS schema-lift
# reader to walk the length-prefix-concat byte stream) live in the
# shared :mod:`ttio.codecs._varint` helper.
from .codecs.rans import decode as _rans_decode
from .codecs._varint import varint_decode as _varint_decode


# v1.6 (L4): _INTEGER_CHANNEL_DTYPES removed. The dict only ever
# contained positions/flags/mapping_qualities, all dropped from
# signal_channels/ in v1.6 — see docs/format-spec.md §10.7.
# The companion _int_channel_array helper has been removed below.

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

    # v1.8 #11: cached whole-sequence decode from the refdiff_v2 blob.
    # None = not yet probed; b"" = probed and found to be v1/BASE_PACK;
    # non-empty bytes = decoded concatenated sequence bytes (total_bases long).
    # Populated on first access by _sequences_is_ref_diff_v2() +
    # _decode_ref_diff_v2_sequences(). Cache lifetime = GenomicRun instance.
    _decoded_ref_diff_v2: "bytes | None" = field(
        default=None, repr=False, compare=False,
    )
    # None = not yet probed; True/False = cached probe result.
    _sequences_is_v2_cached: "bool | None" = field(
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

        v1.8 extension: when ``name == "sequences"`` and the link at
        signal_channels/sequences is a GROUP (refdiff_v2 layout), the
        v2 decode path is used and the result is stored in
        ``_decoded_ref_diff_v2`` / ``_decoded_byte_channels["sequences"]``.
        """
        cached = self._decoded_byte_channels.get(name)
        if cached is not None:
            return cached[offset:offset + count]

        # v1.8 probe: for sequences, check for the group layout first.
        if name == "sequences" and self._sequences_is_ref_diff_v2():
            decoded = self._decode_ref_diff_v2_sequences()
            self._decoded_byte_channels[name] = decoded
            return decoded[offset:offset + count]

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
            # v1.0 reset (Phase 2c): the v1 REF_DIFF (codec id 9)
            # decoder was removed; readers reject these files with a
            # clear migration message pointing at REF_DIFF_V2.
            raise ValueError(
                "signal_channel 'sequences': @compression=9 "
                "(REF_DIFF v1) is no longer supported in v1.0; this "
                "file was written with an older TTI-O version. "
                "Re-encode with v1.0+ which uses REF_DIFF_V2 (codec "
                "id 14)."
            )
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

    def _sequences_is_ref_diff_v2(self) -> bool:
        """True iff signal_channels/sequences is a GROUP containing refdiff_v2.

        v1.8+ layout: sequences is a group with a refdiff_v2 child dataset
        (@compression = 14). Result is cached via ``_sequences_is_v2_cached``.
        """
        if self._sequences_is_v2_cached is not None:
            return self._sequences_is_v2_cached
        sig = self.group.open_group("signal_channels")
        try:
            seq_grp = sig.open_group("sequences")
            # It's a group — check for the refdiff_v2 child dataset.
            try:
                seq_grp.open_dataset("refdiff_v2")
                result = True
            except KeyError:
                result = False
        except KeyError:
            # sequences is a dataset (v1) — not v2.
            result = False
        self._sequences_is_v2_cached = result
        return result

    def _decode_ref_diff_v2_sequences(self) -> bytes:
        """Decode the refdiff_v2 blob; cache and return the flat sequence bytes.

        Returns concatenated per-read sequence bytes (total_bases long) —
        identical contract to the M82 sequences channel.

        Raises:
            RefMissingError: when the reference cannot be resolved.
            RuntimeError: when the native lib is unavailable.
        """
        if self._decoded_ref_diff_v2 is not None:
            return self._decoded_ref_diff_v2

        from .codecs import ref_diff_v2 as _rdv2
        from .genomic.reference_resolver import ReferenceResolver
        from .acquisition_run import _native_h5py

        if not _rdv2.HAVE_NATIVE_LIB:
            raise RuntimeError(
                "REF_DIFF_V2 decode requires libttio_rans "
                "(set TTIO_RANS_LIB_PATH env var)"
            )

        sig = self.group.open_group("signal_channels")
        seq_grp = sig.open_group("sequences")
        ds = seq_grp.open_dataset("refdiff_v2")

        codec_id = io.read_int_attr(ds, "compression", default=0) or 0
        if codec_id != int(Compression.REF_DIFF_V2):
            raise ValueError(
                f"signal_channels/sequences/refdiff_v2: @compression={codec_id}, "
                f"expected REF_DIFF_V2 = {int(Compression.REF_DIFF_V2)}"
            )

        blob = bytes(ds.read(offset=0, count=int(ds.length)))

        # Parse the outer header to extract reference_uri and reference_md5.
        header = _rdv2.parse_blob_header(blob)

        # Resolve reference via the same chain as v1 REF_DIFF.
        try:
            h5_grp = _native_h5py(self.group)
        except TypeError as exc:
            raise RuntimeError(
                "REF_DIFF_V2 decode requires an HDF5-backed dataset; "
                "non-HDF5 storage providers are not yet supported."
            ) from exc
        h5_file = h5_grp.file
        resolver = ReferenceResolver(h5_file)

        unique_chroms = set(self.index.chromosomes)
        if len(unique_chroms) == 0:
            chrom = ""
        elif len(unique_chroms) > 1:
            raise RuntimeError(
                "REF_DIFF_V2 v1.8 supports single-chromosome runs only; "
                f"this run carries {sorted(unique_chroms)}."
            )
        else:
            chrom = next(iter(unique_chroms))

        chrom_seq = resolver.resolve(
            uri=header.reference_uri,
            expected_md5=header.reference_md5,
            chromosome=chrom,
        )

        n = self.index.count
        positions = np.asarray(self.index.positions, dtype=np.int64)
        cigars = self._all_cigars()
        total_bases = int(sum(self.index.lengths))

        out_seq, _ = _rdv2.decode(blob, positions, cigars, chrom_seq, n, total_bases)
        decoded = bytes(out_seq)
        self._decoded_ref_diff_v2 = decoded
        return decoded

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

    # v1.6 (L4): _int_channel_array removed. The helper supported
    # reading positions/flags/mapping_qualities from signal_channels/
    # via codec dispatch — but the per-record reader path (__getitem__)
    # always used genomic_index/ via self.index.{positions,...}. With
    # v1.6 dropping the signal_channels/ duplicates, no caller has a
    # reason to use this helper. See docs/format-spec.md §10.7.

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
        """Return the read name at index ``i``.

        v1.0 reset (Phase 2c): read_names is always a flat 1-D uint8
        dataset encoded with NAME_TOKENIZED_V2 (codec id 15). The v1
        NAME_TOKENIZED (codec id 8) decoder and the M82 compound
        fallback were both removed; readers reject the v1 layout
        with a clear migration error. Decoded names are cached as a
        ``list[str]`` on this :class:`GenomicRun` instance.
        """
        cached = self._decoded_read_names
        if cached is not None:
            return cached[i]

        sig = self.group.open_group("signal_channels")
        ds = sig.open_dataset("read_names")

        if ds.precision != Precision.UINT8:
            raise ValueError(
                "signal_channel 'read_names': dataset is not a flat "
                "uint8 codec stream — the v1.0 reader requires the "
                "NAME_TOKENIZED_V2 layout. The legacy M82 compound "
                "VL-string layout is no longer supported; this file "
                "was written with an older TTI-O version. Re-encode "
                "with v1.0+."
            )

        codec_id = io.read_int_attr(ds, "compression", default=0) or 0
        if codec_id == int(Compression.NAME_TOKENIZED):
            raise ValueError(
                "signal_channel 'read_names': @compression=8 "
                "(NAME_TOKENIZED v1) is no longer supported in v1.0; "
                "this file was written with an older TTI-O version. "
                "Re-encode with v1.0+ which uses NAME_TOKENIZED_V2 "
                "(codec id 15)."
            )
        if codec_id == int(Compression.NAME_TOKENIZED_V2):
            from .codecs import name_tokenizer_v2 as _nt2
            all_bytes = bytes(ds.read(offset=0, count=int(ds.length)))
            self._decoded_read_names = _nt2.decode(all_bytes)
            return self._decoded_read_names[i]
        raise ValueError(
            f"signal_channel 'read_names': @compression={codec_id} "
            "is not a supported TTIO codec id for the read_names "
            "channel (only NAME_TOKENIZED_V2 = 15 is recognised)"
        )

    def _cigar_at(self, i: int) -> str:
        """Return the cigar string at index ``i``, dispatching on shape.

        M86 Phase C: cigars has two on-disk layouts (Binding
        Decisions §120-§123):

        - **M82 compound** (no override): VL_STRING-in-compound
          dataset, read whole-and-cache via :meth:`_compound`.
        - **rANS codec** (override active): flat 1-D uint8 dataset
          carrying a length-prefix-concat byte stream
          (``varint(len) + bytes`` per CIGAR — §2.5 of the Phase C
          plan / format-spec §10.6 extended). Decoded once on first
          access and cached as a ``list[str]`` per Binding Decision
          §123. Two codec ids are recognised: ``RANS_ORDER0`` (4)
          and ``RANS_ORDER1`` (5).

        v1.0 reset (Phase 2c): the v1 ``NAME_TOKENIZED`` (codec id 8)
        cigars decoder was removed; readers reject these files with a
        clear migration error.

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
                _vd = _varint_decode
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
                raise ValueError(
                    "signal_channel 'cigars': @compression=8 "
                    "(NAME_TOKENIZED v1) is no longer supported in "
                    "v1.0; this file was written with an older TTI-O "
                    "version. Re-encode with v1.0+ which uses "
                    "RANS_ORDER0/RANS_ORDER1 for the cigars channel."
                )
            raise ValueError(
                f"signal_channel 'cigars': @compression={codec_id} "
                "is not a supported TTIO codec id for the cigars "
                "channel (only RANS_ORDER0 = 4 and RANS_ORDER1 = 5 "
                "are recognised)"
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

    def _mate_info_is_inline_v2(self) -> bool:
        """True iff signal_channels/mate_info/inline_v2 exists.

        v1.7+ inline-v2 layout. Implies _mate_info_is_subgroup() == True.
        Result is cached via _decoded_mate_info sentinel key.
        """
        if not self._mate_info_is_subgroup():
            return False
        cached = self._decoded_mate_info.get("_is_inline_v2")
        if cached is not None:
            return cached
        sig = self.group.open_group("signal_channels")
        mate_group = sig.open_group("mate_info")
        try:
            mate_group.open_dataset("inline_v2")
            result = True
        except KeyError:
            result = False
        self._decoded_mate_info["_is_inline_v2"] = result
        return result

    def _decode_mate_inline_v2(self) -> "dict[str, Any]":
        """Decode the inline_v2 blob; cache all three fields together.

        Returns the _decoded_mate_info dict populated with keys:
        'chrom' (list[str]), 'pos' (np.int64 array), 'tlen' (np.int32
        array). Reader-side dependency: own_positions and own_chrom_ids
        reconstructed from genomic_index; chrom name resolution uses
        the mate_info/chrom_names table written alongside the blob.
        """
        if "inline_v2" in self._decoded_mate_info:
            return self._decoded_mate_info

        from .codecs import mate_info_v2 as _miv2

        sig = self.group.open_group("signal_channels")
        mate_group = sig.open_group("mate_info")
        ds = mate_group.open_dataset("inline_v2")
        blob = bytes(np.asarray(ds.read(offset=0, count=int(ds.length))).tobytes())

        n = self.index.count
        own_positions = np.asarray(self.index.positions, dtype=np.int64)

        # Build own_chrom_ids (uint16) from the index chromosomes list
        # using encounter-order assignment — same as the writer.
        name_to_id: dict[str, int] = {}
        own_chrom_ids = np.empty(n, dtype=np.uint16)
        for i, name in enumerate(self.index.chromosomes):
            if name == "*" or not name:
                own_chrom_ids[i] = 0xFFFF
            else:
                if name not in name_to_id:
                    name_to_id[name] = len(name_to_id)
                own_chrom_ids[i] = name_to_id[name]

        mc, mp, ts = _miv2.decode(blob, own_chrom_ids, own_positions,
                                   n_records=n)

        # Read the full chrom_id → name table written by the writer.
        # This covers mate-only chromosomes absent from genomic_index.
        chrom_name_rows = io.read_compound_dataset(mate_group, "chrom_names")
        chrom_names_by_id: list[str] = []
        for row in chrom_name_rows:
            v = row["name"]
            chrom_names_by_id.append(
                v.decode("utf-8") if isinstance(v, bytes) else v
            )

        # Convert mc (int32 ids, -1 = unmapped) back to mate_chromosomes list[str].
        mate_chromosomes: list[str] = []
        for v in mc:
            iv = int(v)
            if iv == -1:
                mate_chromosomes.append("*")
            elif 0 <= iv < len(chrom_names_by_id):
                mate_chromosomes.append(chrom_names_by_id[iv])
            else:
                # Should not happen in well-formed files.
                mate_chromosomes.append(f"chr_id_{iv}")

        self._decoded_mate_info["chrom"] = mate_chromosomes
        self._decoded_mate_info["pos"] = mp
        self._decoded_mate_info["tlen"] = ts
        self._decoded_mate_info["inline_v2"] = True  # marker for round-trip cache
        return self._decoded_mate_info

    def _raise_unsupported_mate_layout(self) -> None:
        """Raise a clear migration error for any non-inline_v2 mate_info layout.

        v1.0 reset (Phase 2c): the M86 Phase F per-field subgroup
        layout (with chrom / pos / tlen child datasets) and the
        legacy M82 compound dataset layout were both removed. Only
        the v1.7+ inline_v2 BLOB path under
        ``signal_channels/mate_info/inline_v2`` (codec id 13) is
        decoded; everything else surfaces a clear error so callers
        learn they need to re-encode with v1.0+.
        """
        raise ValueError(
            "signal_channels/mate_info: legacy layout detected — "
            "the v1.0 reader requires the inline_v2 blob "
            "(signal_channels/mate_info/inline_v2 with @compression=13). "
            "The M86 Phase F per-field subgroup (chrom/pos/tlen) and "
            "the M82 compound dataset layouts were removed in v1.0. "
            "This file was written with an older TTI-O version; "
            "re-encode with v1.0+ to use MATE_INLINE_V2."
        )

    def _mate_chrom_at(self, i: int) -> str:
        """Return the mate chromosome at index ``i``.

        v1.0 reset (Phase 2c): only the v1.7+ inline_v2 layout is
        supported. Any other layout raises ValueError.
        """
        if self._mate_info_is_inline_v2():
            return self._decode_mate_inline_v2()["chrom"][i]
        self._raise_unsupported_mate_layout()
        raise AssertionError("unreachable")  # pragma: no cover

    def _mate_pos_at(self, i: int) -> int:
        """Return the mate position at index ``i``.

        v1.0 reset (Phase 2c): inline_v2 is the only supported layout.
        """
        if self._mate_info_is_inline_v2():
            return int(self._decode_mate_inline_v2()["pos"][i])
        self._raise_unsupported_mate_layout()
        raise AssertionError("unreachable")  # pragma: no cover

    def _mate_tlen_at(self, i: int) -> int:
        """Return the template length at index ``i``.

        v1.0 reset (Phase 2c): inline_v2 is the only supported layout.
        """
        if self._mate_info_is_inline_v2():
            return int(self._decode_mate_inline_v2()["tlen"][i])
        self._raise_unsupported_mate_layout()
        raise AssertionError("unreachable")  # pragma: no cover
