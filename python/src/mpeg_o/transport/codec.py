"""Transport-stream codec: file ↔ transport bytes.

The writer walks a :class:`SpectralDataset` and emits the full
packet sequence specified in ``docs/transport-spec.md``. The reader
ingests a packet stream and materializes it back into a ``.mpgo``
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
from .packets import (
    HEADER_SIZE,
    AccessUnit,
    ChannelData,
    PacketFlag,
    PacketHeader,
    PacketType,
    crc32c,
    now_ns,
    pack_string,
    unpack_string,
)

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
    "MPGOMassSpectrum": 0,
    "MPGONMRSpectrum": 1,
    "MPGONMR2DSpectrum": 2,
    "MPGOFreeInductionDecay": 3,
    "MPGOMSImagePixel": 4,
}
_WIRE_TO_SPECTRUM_CLASS = {v: k for k, v in _SPECTRUM_CLASS_TO_WIRE.items()}


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
        flags = int(PacketFlag.HAS_CHECKSUM) if self._use_checksum else 0
        header = PacketHeader(
            packet_type=int(packet_type),
            flags=flags,
            dataset_id=dataset_id,
            au_sequence=au_sequence,
            payload_length=len(payload),
            timestamp_ns=now_ns(),
        )
        self._stream.write(header.to_bytes())
        self._stream.write(payload)
        if self._use_checksum:
            self._stream.write(struct.pack("<I", crc32c(payload)))

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
        """Walk ``dataset`` and emit the full packet sequence."""
        runs = list(dataset.all_runs.items())
        features = list(dataset.feature_flags.features)
        self.write_stream_header(
            format_version="1.2",
            title=dataset.title or "",
            isa_investigation=dataset.isa_investigation_id or "",
            features=features,
            n_datasets=len(runs),
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
        for i, (name, run) in enumerate(runs, start=1):
            for j, spectrum in enumerate(run):
                au = _spectrum_to_access_unit(
                    spectrum, run, use_compression=self._use_compression
                )
                self.write_access_unit(dataset_id=i, au_sequence=j, au=au)
            self.write_end_of_dataset(dataset_id=i, final_au_sequence=len(run))
        self.write_end_of_stream()


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
    stream into a new ``.mpgo`` file.
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
        """Materialize the stream into a ``.mpgo`` file at ``output_path``."""
        stream_meta: dict = {}
        dataset_metas: dict[int, dict] = {}
        run_data: dict[int, dict] = {}
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
                dataset_metas[meta["dataset_id"]] = meta
                run_data[meta["dataset_id"]] = {
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
                au = AccessUnit.from_bytes(payload)
                prev = last_seq.get(did, -1)
                if header.au_sequence <= prev:
                    raise ValueError(
                        f"non-monotonic au_sequence in dataset {did}: "
                        f"prev={prev}, got={header.au_sequence}"
                    )
                last_seq[did] = header.au_sequence
                _ingest_access_unit(run_data[did], au)
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

        path = SpectralDataset.write_minimal(
            output_path,
            title=stream_meta.get("title", ""),
            isa_investigation_id=stream_meta.get("isa_investigation", ""),
            runs=runs,
            features=list(stream_meta.get("features", [])) or None,
            provider=provider,
        )
        return SpectralDataset.open(path)


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
    mpgo_path: str | Path,
    output: BinaryIO | str | Path,
    *,
    use_checksum: bool = False,
    use_compression: bool = False,
) -> None:
    """Convert a ``.mpgo`` file to a transport stream."""
    with SpectralDataset.open(mpgo_path) as ds, \
            TransportWriter(output,
                              use_checksum=use_checksum,
                              use_compression=use_compression) as tw:
        tw.write_dataset(ds)


def transport_to_file(
    source: BinaryIO | str | Path,
    mpgo_path: str | Path,
    *,
    provider: str = "hdf5",
) -> SpectralDataset:
    """Convert a transport stream to a ``.mpgo`` file."""
    with TransportReader(source) as tr:
        return tr.read_to_dataset(output_path=mpgo_path, provider=provider)
