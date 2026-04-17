"""``AcquisitionRun`` — lazy view over one ``/study/ms_runs/<name>/`` group."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator

import json

import h5py
import numpy as np

from . import _hdf5_io as io
from .axis_descriptor import AxisDescriptor
from .chromatogram import Chromatogram
from .enums import AcquisitionMode, ChromatogramType, Polarity
from .instrument_config import InstrumentConfig
from .mass_spectrum import MassSpectrum
from .nmr_spectrum import NMRSpectrum
from .provenance import ProvenanceRecord
from .signal_array import SignalArray
from .spectrum import Spectrum

# Channel -> default axis metadata for the two spectrum classes we currently
# materialize lazily. Writers may store additional channels; reading an unknown
# channel falls back to a generic "amplitude" axis.
_CHANNEL_AXIS: dict[str, AxisDescriptor] = {
    "mz": AxisDescriptor(name="mz", unit="m/z"),
    "intensity": AxisDescriptor(name="intensity", unit="counts"),
    "chemical_shift": AxisDescriptor(name="chemical_shift", unit="ppm"),
}


@dataclass(slots=True)
class SpectrumIndex:
    """Parallel per-spectrum arrays loaded eagerly at run open time.

    The arrays map 1:1 to the datasets under
    ``/study/ms_runs/<name>/spectrum_index/`` described in §4 of
    ``docs/format-spec.md``. They are small (length = spectrum_count) and
    cheap to hold in memory; signal channels remain lazy.
    """

    offsets: np.ndarray
    lengths: np.ndarray
    retention_times: np.ndarray
    ms_levels: np.ndarray
    polarities: np.ndarray
    precursor_mzs: np.ndarray
    precursor_charges: np.ndarray
    base_peak_intensities: np.ndarray

    @property
    def count(self) -> int:
        return int(self.offsets.shape[0])

    @classmethod
    def read(cls, idx_group: h5py.Group) -> "SpectrumIndex":
        def col(name: str, dtype: str) -> np.ndarray:
            return idx_group[name][()].astype(dtype, copy=False)

        return cls(
            offsets=col("offsets", "<u8"),
            lengths=col("lengths", "<u4"),
            retention_times=col("retention_times", "<f8"),
            ms_levels=col("ms_levels", "<i4"),
            polarities=col("polarities", "<i4"),
            precursor_mzs=col("precursor_mzs", "<f8"),
            precursor_charges=col("precursor_charges", "<i4"),
            base_peak_intensities=col("base_peak_intensities", "<f8"),
        )


@dataclass(slots=True)
class AcquisitionRun:
    """Lazy view over one acquisition run inside an ``.mpgo`` file.

    Spectrum access is zero-copy-aware: the spectrum index is pre-loaded into
    numpy arrays at open time but signal channels are sliced on demand, so
    random access to spectrum *i* touches only the dataset bytes it needs.
    """

    name: str
    group: h5py.Group
    spectrum_class: str
    acquisition_mode: AcquisitionMode
    index: SpectrumIndex
    channel_names: tuple[str, ...]
    instrument_config: InstrumentConfig
    nucleus_type: str = ""
    provenance_json: str = ""
    # M24: chromatogram traces. Empty list on v0.3 files (group absent).
    chromatograms: list[Chromatogram] = field(default_factory=list)
    _signal_cache: dict[str, h5py.Dataset] = field(default_factory=dict, repr=False)
    # M21: eagerly decoded Numpress-delta channels, keyed by channel
    # name. When present, :meth:`_materialize_spectrum` slices from
    # this float64 buffer instead of hitting the HDF5 dataset, because
    # Numpress decoding needs the running-sum prefix of the run.
    _numpress_channels: dict[str, np.ndarray] = field(default_factory=dict, repr=False)

    @classmethod
    def open(cls, group: h5py.Group, name: str) -> "AcquisitionRun":
        mode_raw = io.read_int_attr(group, "acquisition_mode", default=0) or 0
        spectrum_class = io.read_string_attr(
            group, "spectrum_class", default="MPGOMassSpectrum"
        ) or "MPGOMassSpectrum"
        nucleus = io.read_string_attr(group, "nucleus_type", default="") or ""
        prov = io.read_string_attr(group, "provenance_json", default="") or ""

        idx = SpectrumIndex.read(group["spectrum_index"])

        sig_group = group["signal_channels"]
        channel_names_raw = io.read_string_attr(
            sig_group, "channel_names", default="mz,intensity"
        ) or "mz,intensity"
        channel_names = tuple(c for c in channel_names_raw.split(",") if c)

        cfg_group = group.get("instrument_config")
        if cfg_group is None:
            config = InstrumentConfig()
        else:
            config = InstrumentConfig(
                manufacturer=io.read_string_attr(cfg_group, "manufacturer", "") or "",
                model=io.read_string_attr(cfg_group, "model", "") or "",
                serial_number=io.read_string_attr(cfg_group, "serial_number", "") or "",
                source_type=io.read_string_attr(cfg_group, "source_type", "") or "",
                analyzer_type=io.read_string_attr(cfg_group, "analyzer_type", "") or "",
                detector_type=io.read_string_attr(cfg_group, "detector_type", "") or "",
            )

        # M21: detect Numpress-delta channels via the
        # ``<chName>_numpress_fixed_point`` attribute on the
        # signal_channels group, and eagerly decode them here so
        # :meth:`_materialize_spectrum` can just slice a float64 buffer.
        numpress_channels: dict[str, np.ndarray] = {}
        for chName in channel_names:
            scale_attr = f"{chName}_numpress_fixed_point"
            if scale_attr in sig_group.attrs:
                from ._numpress import decode as _np_decode
                ds_name = f"{chName}_values"
                if ds_name not in sig_group:
                    continue
                raw = sig_group[ds_name][()]
                scale = int(sig_group.attrs[scale_attr])
                numpress_channels[chName] = _np_decode(raw, scale)

        return cls(
            name=name,
            group=group,
            spectrum_class=spectrum_class,
            acquisition_mode=AcquisitionMode(mode_raw),
            index=idx,
            channel_names=channel_names,
            instrument_config=config,
            nucleus_type=nucleus,
            provenance_json=prov,
            chromatograms=_read_chromatograms(group),
            _numpress_channels=numpress_channels,
        )

    # ----------------------------------------------------- spectrum access

    def __len__(self) -> int:
        return self.index.count

    def __iter__(self) -> Iterator[Spectrum]:
        for i in range(len(self)):
            yield self[i]

    def provenance(self) -> list[ProvenanceRecord]:
        """Per-run provenance records.

        Prefers the v0.3 compound layout at ``<run>/provenance/steps`` and
        falls back to the v0.2 ``@provenance_json`` attribute. Pre-v0.2
        files (no per-run provenance of any kind) return an empty list.
        """
        if "provenance" in self.group and "steps" in self.group["provenance"]:
            return _decode_provenance_compound(self.group["provenance"], "steps")
        if self.provenance_json:
            return _decode_provenance_json(self.provenance_json)
        return []

    def __getitem__(self, i: int) -> Spectrum:
        if i < 0:
            i += len(self)
        if not 0 <= i < len(self):
            raise IndexError(f"spectrum index {i} out of range [0, {len(self)})")
        return self._materialize_spectrum(i)

    def _signal_dataset(self, channel: str) -> h5py.Dataset:
        ds = self._signal_cache.get(channel)
        if ds is not None:
            return ds
        name = f"{channel}_values"
        if name not in self.group["signal_channels"]:
            raise KeyError(f"signal channel {channel!r} missing under run {self.name!r}")
        ds = self.group["signal_channels"][name]
        self._signal_cache[channel] = ds
        return ds

    def _materialize_spectrum(self, i: int) -> Spectrum:
        offset = int(self.index.offsets[i])
        length = int(self.index.lengths[i])
        end = offset + length

        signal_arrays: dict[str, SignalArray] = {}
        for c in self.channel_names:
            decoded = self._numpress_channels.get(c)
            if decoded is not None:
                arr = decoded[offset:end]
            else:
                try:
                    ds = self._signal_dataset(c)
                except KeyError:
                    continue
                arr = ds[offset:end]
            axis = _CHANNEL_AXIS.get(c, AxisDescriptor(name=c, unit=""))
            signal_arrays[c] = SignalArray.from_numpy(arr, axis=axis)

        polarity = Polarity(int(self.index.polarities[i]))
        base_kwargs = dict(
            signal_arrays=signal_arrays,
            index_position=i,
            scan_time_seconds=float(self.index.retention_times[i]),
            precursor_mz=float(self.index.precursor_mzs[i]),
            precursor_charge=int(self.index.precursor_charges[i]),
        )

        if self.spectrum_class == "MPGONMRSpectrum":
            return NMRSpectrum(nucleus_type=self.nucleus_type, **base_kwargs)
        return MassSpectrum(
            ms_level=int(self.index.ms_levels[i]),
            polarity=polarity,
            **base_kwargs,
        )


# ------------------------------------------------ provenance decoders ---


def _decode_provenance_compound(
    prov_group: h5py.Group, dataset_name: str
) -> list[ProvenanceRecord]:
    records = io.read_compound_dataset(prov_group, dataset_name)
    out: list[ProvenanceRecord] = []
    for r in records:
        out.append(ProvenanceRecord(
            timestamp_unix=int(r.get("timestamp_unix", 0)),
            software=str(r.get("software", "")),
            parameters=_safe_json_dict(r.get("parameters_json", "{}")),
            input_refs=_safe_json_list(r.get("input_refs_json", "[]")),
            output_refs=_safe_json_list(r.get("output_refs_json", "[]")),
        ))
    return out


def _decode_provenance_json(blob: str) -> list[ProvenanceRecord]:
    try:
        data = json.loads(blob) if blob else []
    except json.JSONDecodeError:
        return []
    if not isinstance(data, list):
        return []
    out: list[ProvenanceRecord] = []
    for r in data:
        if not isinstance(r, dict):
            continue
        out.append(ProvenanceRecord(
            timestamp_unix=int(r.get("timestampUnix") or r.get("timestamp_unix") or 0),
            software=str(r.get("software", "")),
            parameters=r.get("parameters", {}) if isinstance(r.get("parameters"), dict) else {},
            input_refs=[str(x) for x in (r.get("inputRefs") or r.get("input_refs") or [])],
            output_refs=[str(x) for x in (r.get("outputRefs") or r.get("output_refs") or [])],
        ))
    return out


def _safe_json_list(value: str | list) -> list[str]:
    if isinstance(value, list):
        return [str(x) for x in value]
    try:
        parsed = json.loads(value) if value else []
    except json.JSONDecodeError:
        return []
    return [str(x) for x in parsed] if isinstance(parsed, list) else []


def _safe_json_dict(value: str | dict) -> dict[str, object]:
    if isinstance(value, dict):
        return value
    try:
        parsed = json.loads(value) if value else {}
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


# ----------------------------------------------------- M24 chromatograms ---


def _read_chromatograms(run_group: h5py.Group) -> list[Chromatogram]:
    """Read ``<run>/chromatograms/`` into a list of :class:`Chromatogram`.

    Returns an empty list when the group is absent (v0.3 backward compat).
    """
    if "chromatograms" not in run_group:
        return []
    g = run_group["chromatograms"]
    count = int(g.attrs.get("count", 0))
    if count <= 0:
        return []
    time_all = g["time_values"][()]
    int_all  = g["intensity_values"][()]
    idx = g["chromatogram_index"]
    offsets       = idx["offsets"][()]
    lengths       = idx["lengths"][()]
    types         = idx["types"][()]
    target_mzs    = idx["target_mzs"][()]
    precursor_mzs = idx["precursor_mzs"][()]
    product_mzs   = idx["product_mzs"][()]

    from .signal_array import SignalArray

    out: list[Chromatogram] = []
    for i in range(count):
        off = int(offsets[i])
        n   = int(lengths[i])
        out.append(Chromatogram(
            signal_arrays={
                "time": SignalArray(data=np.asarray(time_all[off:off+n], dtype="<f8").copy()),
                "intensity": SignalArray(data=np.asarray(int_all[off:off+n], dtype="<f8").copy()),
            },
            axes=[],
            chromatogram_type=ChromatogramType(int(types[i])),
            target_mz=float(target_mzs[i]),
            precursor_mz=float(precursor_mzs[i]),
            product_mz=float(product_mzs[i]),
        ))
    return out


def write_chromatograms_to_run_group(
    run_group: h5py.Group, chromatograms: list[Chromatogram]
) -> None:
    """Write ``chromatograms`` under ``<run>/chromatograms/``.

    Does nothing when the list is empty so v0.3 readers continue to see
    the absence of the group. Layout mirrors the ObjC writer for byte
    parity in the cross-compat tests.
    """
    if not chromatograms:
        return
    g = run_group.create_group("chromatograms")
    g.attrs["count"] = np.int64(len(chromatograms))

    total = sum(len(c.time_array) for c in chromatograms)
    time_all = np.empty(total, dtype="<f8")
    int_all  = np.empty(total, dtype="<f8")
    offsets  = np.empty(len(chromatograms), dtype="<i8")
    lengths  = np.empty(len(chromatograms), dtype="<u4")
    types    = np.empty(len(chromatograms), dtype="<i4")
    targets  = np.empty(len(chromatograms), dtype="<f8")
    precs    = np.empty(len(chromatograms), dtype="<f8")
    prods    = np.empty(len(chromatograms), dtype="<f8")

    cursor = 0
    for i, c in enumerate(chromatograms):
        n = len(c.time_array)
        time_all[cursor:cursor+n] = c.time_array.data.astype("<f8", copy=False)
        int_all [cursor:cursor+n] = c.intensity_array.data.astype("<f8", copy=False)
        offsets[i] = cursor
        lengths[i] = n
        types[i]   = int(c.chromatogram_type)
        targets[i] = c.target_mz
        precs[i]   = c.precursor_mz
        prods[i]   = c.product_mz
        cursor += n

    g.create_dataset("time_values",      data=time_all)
    g.create_dataset("intensity_values", data=int_all)
    idx = g.create_group("chromatogram_index")
    idx.create_dataset("offsets",       data=offsets)
    idx.create_dataset("lengths",       data=lengths)
    idx.create_dataset("types",         data=types)
    idx.create_dataset("target_mzs",    data=targets)
    idx.create_dataset("precursor_mzs", data=precs)
    idx.create_dataset("product_mzs",   data=prods)
