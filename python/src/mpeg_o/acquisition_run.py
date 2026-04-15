"""``AcquisitionRun`` — lazy view over one ``/study/ms_runs/<name>/`` group."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator

import json

import h5py
import numpy as np

from . import _hdf5_io as io
from .axis_descriptor import AxisDescriptor
from .enums import AcquisitionMode, Polarity
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

        channels: dict[str, SignalArray] = {}
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
            channels[c] = SignalArray.from_numpy(arr, axis=axis)

        polarity = Polarity(int(self.index.polarities[i]))
        common = dict(
            channels=channels,
            retention_time=float(self.index.retention_times[i]),
            ms_level=int(self.index.ms_levels[i]),
            polarity=polarity,
            precursor_mz=float(self.index.precursor_mzs[i]),
            precursor_charge=int(self.index.precursor_charges[i]),
            base_peak_intensity=float(self.index.base_peak_intensities[i]),
            index=i,
            run_name=self.name,
        )

        if self.spectrum_class == "MPGONMRSpectrum":
            return NMRSpectrum(nucleus=self.nucleus_type, **common)
        return MassSpectrum(**common)


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
