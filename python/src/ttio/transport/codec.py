"""Transport-stream codec: file ↔ transport bytes.

The writer walks a :class:`SpectralDataset` and emits the full
packet sequence specified in ``docs/transport-spec.md``. The reader
ingests a packet stream and materializes it back into a ``.tio``
file via :meth:`SpectralDataset.write_minimal`.

Scope:

- Signal data is emitted as ``float64``. On-wire compression via
  ``Compression.ZLIB`` is opt-in (``TransportWriter(use_compression=True)``)
  and handled automatically by :class:`TransportReader` regardless.
- ProtectionMetadata / Annotation / Provenance / Chromatogram
  packet slots are defined on the wire but writer emission and
  reader materialization of encrypted AUs remain v1.0 integration
  items (the wire is stable as of M71).
- Selective-access filtering lives in M68 (server) and M71 (filter
  enforcement).
"""
from __future__ import annotations

import json
import struct
import zlib
from pathlib import Path
from typing import BinaryIO, Iterator

import numpy as np

from ..acquisition_run import AcquisitionRun
from ..enums import Compression, Polarity, Precision
from ..mass_spectrum import MassSpectrum
from ..spectral_dataset import SpectralDataset, WrittenRun
from ..spectrum import Spectrum
from .._hdf5_io import read_int_attr as io_attr_int  # M90.10 wire codec probe
from .packets import (
    HEADER_MAGIC,
    HEADER_SIZE,
    VERSION,
    AccessUnit,
    ChannelData,
    PacketFlag,
    PacketHeader,
    PacketType,
    _AU_PIXEL_STRUCT,
    _AU_PREFIX_STRUCT,
    _CHANNEL_NAMELEN_STRUCT,
    _CHANNEL_SUFFIX_STRUCT,
    _HEADER_STRUCT,
    crc32c,
    now_ns,
    pack_string,
    unpack_string,
)

_CHECKSUM_STRUCT = struct.Struct("<I")

# ---------------------------------------------------------- wire mappings

# Wire polarity (0=positive, 1=negative, 2=unknown) vs Polarity enum
# (UNKNOWN=0, POSITIVE=1, NEGATIVE=-1). The transport spec uses a
# nonneg-only layout for portability across languages that can't
# round-trip negative uint8 values.
_POLARITY_TO_WIRE = {
    Polarity.POSITIVE: 0,
    Polarity.NEGATIVE: 1,
    Polarity.UNKNOWN: 2,
}
_WIRE_TO_POLARITY = {v: k for k, v in _POLARITY_TO_WIRE.items()}

_SPECTRUM_CLASS_TO_WIRE = {
    "TTIOMassSpectrum": 0,
    "TTIONMRSpectrum": 1,
    "TTIONMR2DSpectrum": 2,
    "TTIOFreeInductionDecay": 3,
    "TTIOMSImagePixel": 4,
    "TTIOGenomicRead": 5,  # M89.2
}
_WIRE_TO_SPECTRUM_CLASS = {v: k for k, v in _SPECTRUM_CLASS_TO_WIRE.items()}


# M90.10: M86 codec dispatch for genomic UINT8 channels on the wire.

_RANS_ORDER0_WIRE = int(Compression.RANS_ORDER0)
_RANS_ORDER1_WIRE = int(Compression.RANS_ORDER1)
_BASE_PACK_WIRE = int(Compression.BASE_PACK)


def _apply_wire_codec(plaintext: bytes, codec: int) -> bytes:
    """Encode ``plaintext`` with the wire codec id (NONE → identity)."""
    if codec == 0:  # NONE
        return plaintext
    if codec == _RANS_ORDER0_WIRE:
        from ..codecs import rans
        return rans.encode(plaintext, order=0)
    if codec == _RANS_ORDER1_WIRE:
        from ..codecs import rans
        return rans.encode(plaintext, order=1)
    if codec == _BASE_PACK_WIRE:
        from ..codecs import base_pack
        return base_pack.encode(plaintext)
    # Other compression ids (zlib for MS, etc.) take the existing
    # paths in this module; this helper is genomic-channel-only.
    raise NotImplementedError(
        f"_apply_wire_codec: codec id {codec} not supported for genomic UINT8"
    )


def _decode_wire_codec(payload: bytes, codec: int) -> bytes:
    """Decode a payload encoded by :func:`_apply_wire_codec`."""
    if codec == 0:
        return payload
    if codec == _RANS_ORDER0_WIRE or codec == _RANS_ORDER1_WIRE:
        from ..codecs import rans
        return rans.decode(payload)
    if codec == _BASE_PACK_WIRE:
        from ..codecs import base_pack
        return base_pack.decode(payload)
    raise NotImplementedError(
        f"_decode_wire_codec: codec id {codec} not supported for genomic UINT8"
    )


# ---------------------------------------------------------- TransportWriter


class TransportWriter:
    """Serialize a :class:`SpectralDataset` as a transport byte stream."""

    def __init__(
        self,
        output: BinaryIO | str | Path,
        *,
        use_checksum: bool = False,
        use_compression: bool = False,
    ):
        self._owns_stream = isinstance(output, (str, Path))
        if self._owns_stream:
            self._stream: BinaryIO = open(output, "wb")  # noqa: SIM115
        else:
            self._stream = output  # type: ignore[assignment]
        self._use_checksum = use_checksum
        self._use_compression = use_compression
        self._stream_header_written = False

    @property
    def use_compression(self) -> bool:
        return self._use_compression

    def __enter__(self) -> "TransportWriter":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def close(self) -> None:
        if self._owns_stream and not self._stream.closed:
            self._stream.close()

    def _emit(
        self,
        packet_type: PacketType,
        payload: bytes,
        *,
        dataset_id: int = 0,
        au_sequence: int = 0,
    ) -> None:
        # Inlined from PacketHeader.to_bytes to skip dataclass construct
        # + method dispatch in the per-spectrum hot path. Same layout.
        flags = int(PacketFlag.HAS_CHECKSUM) if self._use_checksum else 0
        header = _HEADER_STRUCT.pack(
            HEADER_MAGIC,
            VERSION,
            int(packet_type) & 0xFF,
            flags & 0xFFFF,
            dataset_id & 0xFFFF,
            au_sequence & 0xFFFFFFFF,
            len(payload) & 0xFFFFFFFF,
            now_ns() & 0xFFFFFFFFFFFFFFFF,
        )
        if self._use_checksum:
            self._stream.write(header + payload + _CHECKSUM_STRUCT.pack(crc32c(payload)))
        else:
            self._stream.write(header + payload)

    def write_stream_header(
        self,
        *,
        format_version: str,
        title: str,
        isa_investigation: str,
        features: list[str],
        n_datasets: int,
    ) -> None:
        payload = (
            pack_string(format_version, width=2)
            + pack_string(title, width=2)
            + pack_string(isa_investigation, width=2)
            + struct.pack("<H", len(features) & 0xFFFF)
            + b"".join(pack_string(f, width=2) for f in features)
            + struct.pack("<H", n_datasets & 0xFFFF)
        )
        self._emit(PacketType.STREAM_HEADER, payload)
        self._stream_header_written = True

    def write_dataset_header(
        self,
        *,
        dataset_id: int,
        name: str,
        acquisition_mode: int,
        spectrum_class: str,
        channel_names: list[str],
        instrument_json: str,
        expected_au_count: int = 0,
    ) -> None:
        payload = (
            struct.pack("<H", dataset_id & 0xFFFF)
            + pack_string(name)
            + struct.pack("<B", int(acquisition_mode) & 0xFF)
            + pack_string(spectrum_class)
            + struct.pack("<B", len(channel_names) & 0xFF)
            + b"".join(pack_string(c) for c in channel_names)
            + pack_string(instrument_json, width=4)
            + struct.pack("<I", expected_au_count & 0xFFFFFFFF)
        )
        self._emit(PacketType.DATASET_HEADER, payload, dataset_id=dataset_id)

    def write_access_unit(
        self,
        *,
        dataset_id: int,
        au_sequence: int,
        au: AccessUnit,
    ) -> None:
        self._emit(
            PacketType.ACCESS_UNIT,
            au.to_bytes(),
            dataset_id=dataset_id,
            au_sequence=au_sequence,
        )

    def write_end_of_dataset(
        self, *, dataset_id: int, final_au_sequence: int
    ) -> None:
        payload = struct.pack(
            "<HI", dataset_id & 0xFFFF, final_au_sequence & 0xFFFFFFFF
        )
        self._emit(PacketType.END_OF_DATASET, payload, dataset_id=dataset_id)

    def write_end_of_stream(self) -> None:
        self._emit(PacketType.END_OF_STREAM, b"")

    def write_dataset(self, dataset: SpectralDataset) -> None:
        """Walk ``dataset`` and emit the full packet sequence.

        Spectral runs are emitted first (dataset_ids 1..N), then
        genomic runs (dataset_ids N+1..N+M). M89.2 added the genomic
        flow.
        """
        runs = list(dataset.all_runs.items())
        genomic_runs = list(getattr(dataset, "genomic_runs", {}).items())
        features = list(dataset.feature_flags.features)
        self.write_stream_header(
            format_version="1.2",
            title=dataset.title or "",
            isa_investigation=dataset.isa_investigation_id or "",
            features=features,
            n_datasets=len(runs) + len(genomic_runs),
        )
        for i, (name, run) in enumerate(runs, start=1):
            self.write_dataset_header(
                dataset_id=i,
                name=name,
                acquisition_mode=int(run.acquisition_mode),
                spectrum_class=run.spectrum_class,
                channel_names=list(run.channel_names),
                instrument_json=_instrument_config_json(run),
                expected_au_count=len(run),
            )
        for j, (name, grun) in enumerate(genomic_runs, start=len(runs) + 1):
            self.write_dataset_header(
                dataset_id=j,
                name=name,
                acquisition_mode=int(grun.acquisition_mode),
                spectrum_class="TTIOGenomicRead",
                channel_names=["sequences", "qualities",
                               "cigar", "read_name", "mate_chromosome"],
                instrument_json=_genomic_run_metadata_json(grun),
                expected_au_count=len(grun),
            )
        for i, (name, run) in enumerate(runs, start=1):
            self._emit_run_access_units(dataset_id=i, run=run)
            self.write_end_of_dataset(dataset_id=i, final_au_sequence=len(run))
        for j, (name, grun) in enumerate(genomic_runs, start=len(runs) + 1):
            self._emit_genomic_run_access_units(dataset_id=j, run=grun)
            self.write_end_of_dataset(dataset_id=j, final_au_sequence=len(grun))
        self.write_end_of_stream()

    def write_genomic_run(
        self, *, dataset_id: int, name: str, run
    ) -> None:
        """Write a single GenomicRun as a stream segment.

        Used by callers that drive emission manually (multiplexed
        streams, M89.4). The dataset header + AUs + end-of-dataset
        are emitted; the caller is responsible for stream framing.
        """
        self.write_dataset_header(
            dataset_id=dataset_id,
            name=name,
            acquisition_mode=int(run.acquisition_mode),
            spectrum_class="TTIOGenomicRead",
            channel_names=["sequences", "qualities"],
            instrument_json=_genomic_run_metadata_json(run),
            expected_au_count=len(run),
        )
        self._emit_genomic_run_access_units(dataset_id=dataset_id, run=run)
        self.write_end_of_dataset(
            dataset_id=dataset_id, final_au_sequence=len(run)
        )

    def _emit_genomic_run_access_units(self, *, dataset_id: int, run) -> None:
        """Emit one ACCESS_UNIT packet per AlignedRead in ``run``.

        M89.2: per-read fixed fields go into the AU's genomic suffix
        (chromosome / position / mapping_quality / flags). The
        variable-length sequences and qualities arrays ride as two
        UINT8 channels with the per-read slice as data.

        M90.9: compound fields now also round-trip on the wire.
        cigar, read_name, mate_chromosome ride as additional UINT8
        string channels (one per AU). mate_position + template_length
        live in the M90.9 mate extension at the end of the AU genomic
        suffix.

        M90.10: when the source channel carries an ``@compression``
        attribute naming an M86 codec (RANS_ORDER0/1, BASE_PACK), the
        writer re-encodes each per-AU slice with the same codec on
        the wire. The wire ChannelData.compression byte tells the
        reader which decoder to dispatch.
        """
        index = run.index
        n_reads = index.count
        # Bulk-read sequences and qualities once; slice per AU.
        if n_reads > 0:
            total_bases = int(index.offsets[-1]) + int(index.lengths[-1])
            seq_full = run._byte_channel_slice("sequences", 0, total_bases)
            qual_full = run._byte_channel_slice("qualities", 0, total_bases)
        else:
            seq_full = b""
            qual_full = b""
        chromosomes = index.chromosomes
        positions = index.positions
        mqs = index.mapping_qualities
        flags_arr = index.flags
        offsets = index.offsets
        lengths = index.lengths
        precision_uint8 = int(Precision.UINT8) & 0xFF
        compression_none = int(Compression.NONE) & 0xFF
        acq_mode = int(run.acquisition_mode) & 0xFF
        # M90.10: probe source @compression on sequences + qualities
        # so the wire codec mirrors the file's codec choice. The
        # string channels (cigar/read_name/mate_chromosome) always
        # ride uncompressed — they're per-AU short strings where
        # codec framing overhead would dominate.
        seq_codec = qual_codec = compression_none
        try:
            sig_group = run.group.open_group("signal_channels")
            if sig_group.has_child("sequences"):
                seq_ds = sig_group.open_dataset("sequences")
                seq_codec = (io_attr_int(seq_ds, "compression",
                                            default=0) or 0) & 0xFF
            if sig_group.has_child("qualities"):
                qual_ds = sig_group.open_dataset("qualities")
                qual_codec = (io_attr_int(qual_ds, "compression",
                                             default=0) or 0) & 0xFF
        except Exception:
            seq_codec = qual_codec = compression_none

        for i in range(n_reads):
            start = int(offsets[i])
            length = int(lengths[i])
            stop = start + length
            seq_bytes = seq_full[start:stop]
            qual_bytes = qual_full[start:stop]
            # M90.10: re-encode per-AU slice with the M86 codec when
            # the source channel had an @compression attribute set.
            seq_payload = _apply_wire_codec(bytes(seq_bytes), seq_codec)
            qual_payload = _apply_wire_codec(bytes(qual_bytes), qual_codec)
            # M90.9: pull the per-read compound fields off the lazy
            # AlignedRead. read_name / cigar / mate_* go on the wire
            # so a transport round-trip preserves SAM-level fidelity.
            r = run[i]
            cigar_bytes = (r.cigar or "").encode("utf-8")
            name_bytes = (r.read_name or "").encode("utf-8")
            mate_chr_bytes = (r.mate_chromosome or "").encode("utf-8")
            channels = [
                ChannelData("sequences", precision_uint8,
                            seq_codec, length, seq_payload),
                ChannelData("qualities", precision_uint8,
                            qual_codec, length, qual_payload),
                ChannelData("cigar", precision_uint8,
                            compression_none, len(cigar_bytes), cigar_bytes),
                ChannelData("read_name", precision_uint8,
                            compression_none, len(name_bytes), name_bytes),
                ChannelData("mate_chromosome", precision_uint8,
                            compression_none, len(mate_chr_bytes),
                            mate_chr_bytes),
            ]
            au = AccessUnit(
                spectrum_class=5,
                acquisition_mode=acq_mode,
                ms_level=0,
                polarity=2,
                retention_time=0.0,
                precursor_mz=0.0,
                precursor_charge=0,
                ion_mobility=0.0,
                base_peak_intensity=0.0,
                channels=channels,
                chromosome=chromosomes[i],
                position=int(positions[i]),
                mapping_quality=int(mqs[i]),
                flags=int(flags_arr[i]) & 0xFFFF,
                mate_position=int(r.mate_position),
                template_length=int(r.template_length),
            )
            self.write_access_unit(
                dataset_id=dataset_id, au_sequence=i, au=au
            )

    def _emit_run_access_units(
        self, *, dataset_id: int, run: AcquisitionRun
    ) -> None:
        """Hot path: emit AccessUnit packets for every spectrum in ``run``.

        Bulk-reads each channel dataset once up-front and slices per AU.
        Skips per-spectrum ``_materialize_spectrum`` (which was ~60% of
        encode walltime through h5py hyperslab reads) and dataclass
        constructions.
        """
        # Pre-compute everything stable across spectra once per run.
        channel_names = list(run.channel_names)
        channel_name_prefixes = [
            _CHANNEL_NAMELEN_STRUCT.pack(len(nb)) + nb
            for nb in (cn.encode("utf-8") for cn in channel_names)
        ]
        wire_class = _SPECTRUM_CLASS_TO_WIRE.get(run.spectrum_class, 0) & 0xFF
        acq_mode = int(run.acquisition_mode) & 0xFF
        is_ms_class = run.spectrum_class == "TTIOMassSpectrum"
        is_pixel_class = wire_class == 4
        use_compression = self._use_compression
        compression_enum = int(Compression.ZLIB if use_compression else Compression.NONE) & 0xFF
        precision_enum = int(Precision.FLOAT64) & 0xFF
        unknown_polarity_wire = _POLARITY_TO_WIRE[Polarity.UNKNOWN]

        # Bulk-read channel arrays once instead of per-spectrum.
        index = run.index
        total_count = int(index.offsets[-1] + index.lengths[-1]) if len(index.offsets) > 0 else 0
        channel_arrays: list[tuple[int, np.ndarray] | None] = []
        for ci, cname in enumerate(channel_names):
            decoded = run._numpress_channels.get(cname)
            if decoded is not None:
                arr = np.ascontiguousarray(decoded, dtype="<f8")
                channel_arrays.append((ci, arr))
                continue
            try:
                ds = run._signal_dataset(cname)
            except KeyError:
                channel_arrays.append(None)
                continue
            arr = np.ascontiguousarray(np.asarray(ds.read(offset=0, count=total_count)), dtype="<f8")
            channel_arrays.append((ci, arr))

        # Index columns are numpy arrays already — slice per-i.
        offsets = index.offsets
        lengths = index.lengths
        rts = index.retention_times
        pmzs = index.precursor_mzs
        pcs = index.precursor_charges
        bpis = index.base_peak_intensities
        ms_levels = index.ms_levels
        polarities_wire = (
            np.array(
                [_POLARITY_TO_WIRE.get(Polarity(int(p)), 2) for p in index.polarities],
                dtype="<i4",
            )
            if is_ms_class
            else None
        )

        # Hoist method lookups out of the loop.
        stream_write = self._stream.write
        header_pack = _HEADER_STRUCT.pack
        au_prefix_pack = _AU_PREFIX_STRUCT.pack
        channel_suffix_pack = _CHANNEL_SUFFIX_STRUCT.pack
        pixel_pack = _AU_PIXEL_STRUCT.pack
        crc32c_ = crc32c
        checksum_pack = _CHECKSUM_STRUCT.pack
        zlib_compress = zlib.compress
        use_checksum = self._use_checksum
        flags = int(PacketFlag.HAS_CHECKSUM) if use_checksum else 0
        ac_type = int(PacketType.ACCESS_UNIT) & 0xFF
        now_ns_ = now_ns
        did = dataset_id & 0xFFFF

        n_spectra = len(run)
        for j in range(n_spectra):
            start = int(offsets[j])
            length = int(lengths[j])
            stop = start + length

            # Channel data collection from pre-loaded arrays.
            channel_chunks: list[bytes] = []
            n_channels = 0
            for slot in channel_arrays:
                if slot is None:
                    continue
                ci, full_arr = slot
                raw = full_arr[start:stop].tobytes()
                payload_bytes = zlib_compress(raw) if use_compression else raw
                channel_chunks.append(channel_name_prefixes[ci])
                channel_chunks.append(channel_suffix_pack(
                    precision_enum,
                    compression_enum,
                    length & 0xFFFFFFFF,
                    len(payload_bytes) & 0xFFFFFFFF,
                ))
                channel_chunks.append(payload_bytes)
                n_channels += 1

            if is_ms_class:
                ms_level = int(ms_levels[j])
                polarity_wire = int(polarities_wire[j]) if polarities_wire is not None else unknown_polarity_wire
            else:
                ms_level = 0
                polarity_wire = unknown_polarity_wire

            au_prefix = au_prefix_pack(
                wire_class,
                acq_mode,
                ms_level & 0xFF,
                polarity_wire & 0xFF,
                float(rts[j]),
                float(pmzs[j]),
                int(pcs[j]) & 0xFF,
                0.0,
                float(bpis[j]),
                n_channels & 0xFF,
            )
            payload_parts = [au_prefix, *channel_chunks]
            if is_pixel_class:
                payload_parts.append(pixel_pack(0, 0, 0))
            payload = b"".join(payload_parts)

            header = header_pack(
                HEADER_MAGIC,
                VERSION,
                ac_type,
                flags & 0xFFFF,
                did,
                j & 0xFFFFFFFF,
                len(payload) & 0xFFFFFFFF,
                now_ns_() & 0xFFFFFFFFFFFFFFFF,
            )
            if use_checksum:
                stream_write(header + payload + checksum_pack(crc32c_(payload)))
            else:
                stream_write(header + payload)


def _instrument_config_json(run: AcquisitionRun) -> str:
    cfg = run.instrument_config
    return json.dumps({
        "manufacturer": cfg.manufacturer,
        "model": cfg.model,
        "serial_number": cfg.serial_number,
        "source_type": cfg.source_type,
        "analyzer_type": cfg.analyzer_type,
        "detector_type": cfg.detector_type,
    }, sort_keys=True)


def _genomic_run_metadata_json(run) -> str:
    """Serialise per-genomic-run metadata for the dataset header.

    Reuses the instrument_json slot in the DATASET_HEADER packet —
    GenomicRun has its own metadata fields (reference_uri, platform,
    sample_name) instead of an InstrumentConfig. M89.2.
    """
    return json.dumps({
        "reference_uri": getattr(run, "reference_uri", "") or "",
        "platform": getattr(run, "platform", "") or "",
        "sample_name": getattr(run, "sample_name", "") or "",
        "modality": getattr(run, "modality", "") or "",
    }, sort_keys=True)


def _spectrum_to_access_unit(
    spectrum: Spectrum,
    run: AcquisitionRun,
    *,
    use_compression: bool = False,
) -> AccessUnit:
    wire_class = _SPECTRUM_CLASS_TO_WIRE.get(run.spectrum_class, 0)
    ms_level = 0
    polarity_wire = _POLARITY_TO_WIRE[Polarity.UNKNOWN]
    if isinstance(spectrum, MassSpectrum):
        ms_level = spectrum.ms_level
        polarity_wire = _POLARITY_TO_WIRE.get(spectrum.polarity, 2)

    bpi = float(run.index.base_peak_intensity_at(spectrum.index_position))

    channels: list[ChannelData] = []
    for cname in run.channel_names:
        if not spectrum.has_signal_array(cname):
            continue
        sa = spectrum.signal_array(cname)
        arr = np.asarray(sa.data).astype("<f8", copy=False)
        raw = arr.tobytes()
        if use_compression:
            payload = zlib.compress(raw)
            compression = int(Compression.ZLIB)
        else:
            payload = raw
            compression = int(Compression.NONE)
        channels.append(ChannelData(
            name=cname,
            precision=int(Precision.FLOAT64),
            compression=compression,
            n_elements=int(arr.size),
            data=payload,
        ))

    return AccessUnit(
        spectrum_class=wire_class,
        acquisition_mode=int(run.acquisition_mode),
        ms_level=ms_level,
        polarity=polarity_wire,
        retention_time=float(spectrum.scan_time_seconds),
        precursor_mz=float(spectrum.precursor_mz),
        precursor_charge=int(spectrum.precursor_charge),
        ion_mobility=0.0,
        base_peak_intensity=bpi,
        channels=channels,
    )


# ---------------------------------------------------------- TransportReader


class TransportReader:
    """Deserialize a transport byte stream.

    The low-level API :meth:`iter_packets` yields ``(header, payload)``
    pairs. The high-level :meth:`read_to_dataset` materializes the
    stream into a new ``.tio`` file.
    """

    def __init__(self, source: BinaryIO | str | Path):
        self._owns_stream = isinstance(source, (str, Path))
        if self._owns_stream:
            self._stream: BinaryIO = open(source, "rb")  # noqa: SIM115
        else:
            self._stream = source  # type: ignore[assignment]

    def __enter__(self) -> "TransportReader":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def close(self) -> None:
        if self._owns_stream and not self._stream.closed:
            self._stream.close()

    def iter_packets(self) -> Iterator[tuple[PacketHeader, bytes]]:
        while True:
            header_bytes = self._stream.read(HEADER_SIZE)
            if not header_bytes:
                return
            if len(header_bytes) < HEADER_SIZE:
                raise ValueError(
                    f"truncated header: {len(header_bytes)}/{HEADER_SIZE} bytes"
                )
            header = PacketHeader.from_bytes(header_bytes)
            payload = self._stream.read(header.payload_length)
            if len(payload) != header.payload_length:
                raise ValueError(
                    f"truncated payload: {len(payload)}/{header.payload_length}"
                )
            if header.flags & int(PacketFlag.HAS_CHECKSUM):
                crc_bytes = self._stream.read(4)
                if len(crc_bytes) != 4:
                    raise ValueError("truncated CRC-32C")
                (expected_crc,) = struct.unpack("<I", crc_bytes)
                actual_crc = crc32c(payload)
                if expected_crc != actual_crc:
                    raise ValueError(
                        f"CRC-32C mismatch on packet type 0x{header.packet_type:02x}: "
                        f"expected 0x{expected_crc:08x}, got 0x{actual_crc:08x}"
                    )
            yield header, payload
            if header.packet_type == int(PacketType.END_OF_STREAM):
                return

    def read_to_dataset(
        self,
        *,
        output_path: str | Path,
        provider: str = "hdf5",
    ) -> SpectralDataset:
        """Materialize the stream into a ``.tio`` file at ``output_path``."""
        stream_meta: dict = {}
        dataset_metas: dict[int, dict] = {}
        run_data: dict[int, dict] = {}
        genomic_data: dict[int, dict] = {}
        last_seq: dict[int, int] = {}
        saw_stream_header = False

        for header, payload in self.iter_packets():
            ptype = header.packet_type
            if ptype == int(PacketType.STREAM_HEADER):
                if saw_stream_header:
                    raise ValueError("duplicate StreamHeader")
                stream_meta = _decode_stream_header(payload)
                saw_stream_header = True
                continue
            if not saw_stream_header:
                raise ValueError(
                    f"first packet must be StreamHeader, got type 0x{ptype:02x}"
                )
            if ptype == int(PacketType.DATASET_HEADER):
                meta = _decode_dataset_header(payload)
                did = meta["dataset_id"]
                dataset_metas[did] = meta
                # M89.2: genomic datasets get a parallel accumulator.
                if meta["spectrum_class"] == "TTIOGenomicRead":
                    genomic_data[did] = _new_genomic_accumulator()
                else:
                    run_data[did] = {
                        "channels": {c: [] for c in meta["channel_names"]},
                        "offsets": [],
                        "lengths": [],
                        "retention_times": [],
                        "ms_levels": [],
                        "polarities": [],
                        "precursor_mzs": [],
                        "precursor_charges": [],
                        "base_peak_intensities": [],
                        "running_offset": 0,
                    }
            elif ptype == int(PacketType.ACCESS_UNIT):
                did = header.dataset_id
                if did not in dataset_metas:
                    raise ValueError(
                        f"AccessUnit before DatasetHeader for id {did}"
                    )
                prev = last_seq.get(did, -1)
                if header.au_sequence <= prev:
                    raise ValueError(
                        f"non-monotonic au_sequence in dataset {did}: "
                        f"prev={prev}, got={header.au_sequence}"
                    )
                last_seq[did] = header.au_sequence
                if did in genomic_data:
                    _ingest_genomic_access_unit_bytes(
                        genomic_data[did], payload
                    )
                else:
                    _ingest_access_unit_bytes(run_data[did], payload)
            elif ptype == int(PacketType.END_OF_DATASET):
                continue
            elif ptype == int(PacketType.END_OF_STREAM):
                break
            else:
                # Annotation / Provenance / Chromatogram /
                # ProtectionMetadata — recognized but not yet
                # materialized (M70/M71 scope).
                continue

        runs: dict[str, WrittenRun] = {}
        for did, meta in dataset_metas.items():
            if did in genomic_data:
                continue
            rd = run_data[did]
            channel_data = {
                c: (np.concatenate(rd["channels"][c])
                    if rd["channels"][c]
                    else np.array([], dtype="<f8"))
                for c in meta["channel_names"]
            }
            runs[meta["name"]] = WrittenRun(
                spectrum_class=meta["spectrum_class"],
                acquisition_mode=meta["acquisition_mode"],
                channel_data=channel_data,
                offsets=np.array(rd["offsets"], dtype="<u8"),
                lengths=np.array(rd["lengths"], dtype="<u4"),
                retention_times=np.array(rd["retention_times"], dtype="<f8"),
                ms_levels=np.array(rd["ms_levels"], dtype="<i4"),
                polarities=np.array(rd["polarities"], dtype="<i4"),
                precursor_mzs=np.array(rd["precursor_mzs"], dtype="<f8"),
                precursor_charges=np.array(rd["precursor_charges"], dtype="<i4"),
                base_peak_intensities=np.array(
                    rd["base_peak_intensities"], dtype="<f8"
                ),
                signal_compression="gzip",
            )

        # M89.2: build WrittenGenomicRun for each genomic dataset.
        from ..written_genomic_run import WrittenGenomicRun
        genomic_runs: dict[str, WrittenGenomicRun] = {}
        for did, gd in genomic_data.items():
            meta = dataset_metas[did]
            n = len(gd["chromosomes"])
            instrument_meta = json.loads(meta.get("instrument_json") or "{}")
            genomic_runs[meta["name"]] = WrittenGenomicRun(
                acquisition_mode=meta["acquisition_mode"],
                reference_uri=instrument_meta.get("reference_uri", ""),
                platform=instrument_meta.get("platform", ""),
                sample_name=instrument_meta.get("sample_name", ""),
                positions=np.array(gd["positions"], dtype=np.int64),
                mapping_qualities=np.array(gd["mapping_qualities"], dtype=np.uint8),
                flags=np.array(gd["flags"], dtype=np.uint32),
                sequences=(np.concatenate(gd["sequences_chunks"])
                           if gd["sequences_chunks"]
                           else np.array([], dtype=np.uint8)),
                qualities=(np.concatenate(gd["qualities_chunks"])
                           if gd["qualities_chunks"]
                           else np.array([], dtype=np.uint8)),
                offsets=np.array(gd["offsets"], dtype=np.uint64),
                lengths=np.array(gd["lengths"], dtype=np.uint32),
                # M90.9: compound fields now round-trip on the wire.
                # When the source is an M89.2-era stream the per-AU
                # decoders default the missing strings to "" and the
                # mate scalars to -1 / 0 (preserved by the AU
                # decoder + accumulator paths).
                cigars=list(gd["cigars"]) if gd["cigars"]
                        else ["" for _ in range(n)],
                read_names=list(gd["read_names"]) if gd["read_names"]
                            else ["" for _ in range(n)],
                mate_chromosomes=list(gd["mate_chromosomes"])
                                  if gd["mate_chromosomes"]
                                  else ["" for _ in range(n)],
                mate_positions=(np.array(gd["mate_positions"], dtype=np.int64)
                                if gd["mate_positions"]
                                else np.full(n, -1, dtype=np.int64)),
                template_lengths=(np.array(gd["template_lengths"], dtype=np.int32)
                                   if gd["template_lengths"]
                                   else np.zeros(n, dtype=np.int32)),
                chromosomes=list(gd["chromosomes"]),
            )

        path = SpectralDataset.write_minimal(
            output_path,
            title=stream_meta.get("title", ""),
            isa_investigation_id=stream_meta.get("isa_investigation", ""),
            runs=runs,
            genomic_runs=genomic_runs or None,
            features=list(stream_meta.get("features", [])) or None,
            provider=provider,
        )
        return SpectralDataset.open(path)


def _new_genomic_accumulator() -> dict:
    """Per-dataset accumulator for genomic AUs. See M89.2 + M90.9."""
    return {
        "chromosomes": [],
        "positions": [],
        "mapping_qualities": [],
        "flags": [],
        "sequences_chunks": [],
        "qualities_chunks": [],
        "offsets": [],
        "lengths": [],
        "running_offset": 0,
        # M90.9: compound-field accumulators.
        "cigars": [],
        "read_names": [],
        "mate_chromosomes": [],
        "mate_positions": [],
        "template_lengths": [],
    }


def _ingest_genomic_access_unit_bytes(gd: dict, payload: bytes) -> None:
    """Parse a genomic AU payload (spectrum_class==5) into ``gd``.

    Mirrors :func:`_ingest_access_unit_bytes` but extracts the genomic
    suffix (chromosome / position / mapq / flags) and accumulates
    sequences + qualities as concatenated uint8 buffers. M89.2.
    """
    au = AccessUnit.from_bytes(payload)
    if au.spectrum_class != 5:
        raise ValueError(
            f"genomic accumulator received spectrum_class {au.spectrum_class}"
        )
    gd["chromosomes"].append(au.chromosome)
    gd["positions"].append(int(au.position))
    gd["mapping_qualities"].append(int(au.mapping_quality))
    gd["flags"].append(int(au.flags) & 0xFFFFFFFF)
    # M90.9: mate extension fields ride on the AU genomic suffix.
    gd["mate_positions"].append(int(au.mate_position))
    gd["template_lengths"].append(int(au.template_length))
    length = 0
    # M90.9: compound-string channels default to "" if absent (an
    # M89.2-era AU). Channel-name dispatch covers both layouts.
    cigar_str = ""
    name_str = ""
    mate_chr_str = ""
    for ch in au.channels:
        if ch.precision != int(Precision.UINT8):
            raise NotImplementedError(
                f"genomic channel precision {ch.precision} not yet supported "
                "(UINT8 only in M89.2)"
            )
        # M90.10: dispatch on wire compression byte (NONE / RANS_*
        # / BASE_PACK). See _decode_wire_codec.
        decoded = _decode_wire_codec(bytes(ch.data), int(ch.compression))
        if ch.name == "sequences":
            arr = np.frombuffer(decoded, dtype=np.uint8).copy()
            gd["sequences_chunks"].append(arr)
            length = len(arr)
        elif ch.name == "qualities":
            arr = np.frombuffer(decoded, dtype=np.uint8).copy()
            gd["qualities_chunks"].append(arr)
            if length == 0:
                length = len(arr)
        elif ch.name == "cigar":
            cigar_str = decoded.decode("utf-8")
        elif ch.name == "read_name":
            name_str = decoded.decode("utf-8")
        elif ch.name == "mate_chromosome":
            mate_chr_str = decoded.decode("utf-8")
    gd["cigars"].append(cigar_str)
    gd["read_names"].append(name_str)
    gd["mate_chromosomes"].append(mate_chr_str)
    gd["offsets"].append(gd["running_offset"])
    gd["lengths"].append(length)
    gd["running_offset"] += length


def _decode_stream_header(payload: bytes) -> dict:
    offset = 0
    format_version, offset = unpack_string(payload, offset, width=2)
    title, offset = unpack_string(payload, offset, width=2)
    isa_investigation, offset = unpack_string(payload, offset, width=2)
    (n_features,) = struct.unpack_from("<H", payload, offset)
    offset += 2
    features: list[str] = []
    for _ in range(n_features):
        f, offset = unpack_string(payload, offset, width=2)
        features.append(f)
    (n_datasets,) = struct.unpack_from("<H", payload, offset)
    offset += 2
    return {
        "format_version": format_version,
        "title": title,
        "isa_investigation": isa_investigation,
        "features": features,
        "n_datasets": n_datasets,
    }


def _decode_dataset_header(payload: bytes) -> dict:
    offset = 0
    (dataset_id,) = struct.unpack_from("<H", payload, offset)
    offset += 2
    name, offset = unpack_string(payload, offset, width=2)
    (acquisition_mode,) = struct.unpack_from("<B", payload, offset)
    offset += 1
    spectrum_class, offset = unpack_string(payload, offset, width=2)
    (n_channels,) = struct.unpack_from("<B", payload, offset)
    offset += 1
    channel_names: list[str] = []
    for _ in range(n_channels):
        c, offset = unpack_string(payload, offset, width=2)
        channel_names.append(c)
    instrument_json, offset = unpack_string(payload, offset, width=4)
    (expected_au_count,) = struct.unpack_from("<I", payload, offset)
    offset += 4
    return {
        "dataset_id": dataset_id,
        "name": name,
        "acquisition_mode": acquisition_mode,
        "spectrum_class": spectrum_class,
        "channel_names": channel_names,
        "instrument_json": instrument_json,
        "expected_au_count": expected_au_count,
    }


def _ingest_access_unit_bytes(rd: dict, payload: bytes) -> None:
    """Parse an AU payload directly into ``rd``, skipping dataclass construction.

    Equivalent to ``_ingest_access_unit(rd, AccessUnit.from_bytes(payload))`` but
    avoids creating 1 AccessUnit + N ChannelData dataclasses per AU.
    """
    if len(payload) < 38:
        raise ValueError(f"access unit payload too short: {len(payload)}")
    (
        _spectrum_class, _acq_mode, ms_level, polarity_wire,
        retention_time, precursor_mz,
        precursor_charge,
        _ion_mobility, base_peak_intensity,
        n_channels,
    ) = _AU_PREFIX_STRUCT.unpack_from(payload, 0)

    channel_map = rd["channels"]
    offset = 38
    length = 0
    seen: dict[str, bool] = {}
    for _ in range(n_channels):
        (name_len,) = _CHANNEL_NAMELEN_STRUCT.unpack_from(payload, offset)
        offset += 2
        name = bytes(payload[offset:offset + name_len]).decode("utf-8")
        offset += name_len
        precision, compression, n_elements, data_length = _CHANNEL_SUFFIX_STRUCT.unpack_from(
            payload, offset
        )
        offset += 10
        data = bytes(payload[offset:offset + data_length])
        offset += data_length
        if precision != _FLOAT64_WIRE:
            raise NotImplementedError(
                f"precision {precision} not yet supported (FLOAT64 only)"
            )
        if compression == _COMPRESSION_NONE_WIRE:
            raw = data
        elif compression == _COMPRESSION_ZLIB_WIRE:
            raw = zlib.decompress(data)
        else:
            raise NotImplementedError(
                f"compression {compression} not yet supported "
                "(current codec: NONE, ZLIB)"
            )
        arr = np.frombuffer(raw, dtype="<f8").copy()
        seen[name] = True
        if length == 0:
            length = len(arr)
        elif len(arr) != length:
            raise ValueError(
                f"channels in one AU have mismatched lengths: {length} vs {len(arr)}"
            )
        if name in channel_map:
            channel_map[name].append(arr)

    rd["offsets"].append(rd["running_offset"])
    rd["lengths"].append(length)
    rd["running_offset"] += length
    for cname, buckets in channel_map.items():
        if cname not in seen:
            buckets.append(np.zeros(length, dtype="<f8"))

    rd["retention_times"].append(retention_time)
    rd["ms_levels"].append(ms_level)
    rd["polarities"].append(int(_WIRE_TO_POLARITY.get(polarity_wire, Polarity.UNKNOWN)))
    rd["precursor_mzs"].append(precursor_mz)
    rd["precursor_charges"].append(precursor_charge)
    rd["base_peak_intensities"].append(base_peak_intensity)


_FLOAT64_WIRE = int(Precision.FLOAT64)
_COMPRESSION_NONE_WIRE = int(Compression.NONE)
_COMPRESSION_ZLIB_WIRE = int(Compression.ZLIB)


def _ingest_access_unit(rd: dict, au: AccessUnit) -> None:
    arr_by_name: dict[str, np.ndarray] = {}
    for ch in au.channels:
        if ch.precision != int(Precision.FLOAT64):
            raise NotImplementedError(
                f"precision {ch.precision} not yet supported (FLOAT64 only)"
            )
        if ch.compression == int(Compression.NONE):
            raw = ch.data
        elif ch.compression == int(Compression.ZLIB):
            raw = zlib.decompress(ch.data)
        else:
            raise NotImplementedError(
                f"compression {ch.compression} not yet supported "
                "(current codec: NONE, ZLIB)"
            )
        arr_by_name[ch.name] = np.frombuffer(raw, dtype="<f8").copy()

    lengths = {len(a) for a in arr_by_name.values()}
    if len(lengths) > 1:
        raise ValueError(
            f"channels in one AU have mismatched lengths: {sorted(lengths)}"
        )
    length = next(iter(lengths)) if lengths else 0

    rd["offsets"].append(rd["running_offset"])
    rd["lengths"].append(length)
    rd["running_offset"] += length
    for cname in rd["channels"]:
        arr = arr_by_name.get(cname)
        if arr is None:
            arr = np.zeros(length, dtype="<f8")
        rd["channels"][cname].append(arr)

    rd["retention_times"].append(au.retention_time)
    rd["ms_levels"].append(au.ms_level)
    rd["polarities"].append(int(_WIRE_TO_POLARITY.get(au.polarity, Polarity.UNKNOWN)))
    rd["precursor_mzs"].append(au.precursor_mz)
    rd["precursor_charges"].append(au.precursor_charge)
    rd["base_peak_intensities"].append(au.base_peak_intensity)


# ---------------------------------------------------------- convenience


def file_to_transport(
    ttio_path: str | Path,
    output: BinaryIO | str | Path,
    *,
    use_checksum: bool = False,
    use_compression: bool = False,
) -> None:
    """Convert a ``.tio`` file to a transport stream."""
    with SpectralDataset.open(ttio_path) as ds, \
            TransportWriter(output,
                              use_checksum=use_checksum,
                              use_compression=use_compression) as tw:
        tw.write_dataset(ds)


def transport_to_file(
    source: BinaryIO | str | Path,
    ttio_path: str | Path,
    *,
    provider: str = "hdf5",
) -> SpectralDataset:
    """Convert a transport stream to a ``.tio`` file."""
    with TransportReader(source) as tr:
        return tr.read_to_dataset(output_path=ttio_path, provider=provider)
