"""``AcquisitionRun`` — lazy view over one ``/study/ms_runs/<name>/`` group."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator

import h5py
import numpy as np

from . import _hdf5_io as io
from .axis_descriptor import AxisDescriptor
from .enums import AcquisitionMode, Polarity
from .instrument_config import InstrumentConfig
from .mass_spectrum import MassSpectrum
from .nmr_spectrum import NMRSpectrum
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
        )

    # ----------------------------------------------------- spectrum access

    def __len__(self) -> int:
        return self.index.count

    def __iter__(self) -> Iterator[Spectrum]:
        for i in range(len(self)):
            yield self[i]

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
