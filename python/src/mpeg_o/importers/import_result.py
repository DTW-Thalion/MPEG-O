"""``ImportResult`` — lightweight in-memory container produced by importers.

The main ``SpectralDataset`` class wraps an open HDF5 file, which would be
awkward to construct from an importer that has no backing file yet. Instead,
importers produce an :class:`ImportResult` that can be inspected in memory
and then flushed to a real ``.mpgo`` file with :meth:`ImportResult.to_mpgo`.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Iterator

import numpy as np

from ..identification import Identification
from ..provenance import ProvenanceRecord
from ..quantification import Quantification
from ..spectral_dataset import SpectralDataset, WrittenRun


@dataclass(slots=True)
class ImportedSpectrum:
    """One decoded spectrum from an import-time XML parse."""

    mz_or_chemical_shift: np.ndarray
    intensity: np.ndarray
    retention_time: float = 0.0
    ms_level: int = 1
    polarity: int = 0  # Polarity enum value
    precursor_mz: float = 0.0
    precursor_charge: int = 0


@dataclass(slots=True)
class ImportResult:
    """Container returned by the mzML / nmrML importers."""

    title: str = ""
    isa_investigation_id: str = ""
    ms_spectra: list[ImportedSpectrum] = field(default_factory=list)
    nmr_spectra: list[ImportedSpectrum] = field(default_factory=list)
    nucleus_type: str = ""
    identifications: list[Identification] = field(default_factory=list)
    quantifications: list[Quantification] = field(default_factory=list)
    provenance: list[ProvenanceRecord] = field(default_factory=list)
    source_file: str = ""

    def __iter__(self) -> Iterator[ImportedSpectrum]:
        yield from self.ms_spectra
        yield from self.nmr_spectra

    @property
    def spectrum_count(self) -> int:
        return len(self.ms_spectra) + len(self.nmr_spectra)

    def build_runs(self) -> dict[str, WrittenRun]:
        """Convert the parsed spectra into ``WrittenRun`` buffers ready for
        :func:`SpectralDataset.write_minimal`.
        """
        runs: dict[str, WrittenRun] = {}
        if self.ms_spectra:
            runs["run_0001"] = _pack_run(
                self.ms_spectra, spectrum_class="MPGOMassSpectrum",
                acquisition_mode=0, channel_x="mz",
            )
        if self.nmr_spectra:
            runs["nmr_run"] = _pack_run(
                self.nmr_spectra, spectrum_class="MPGONMRSpectrum",
                acquisition_mode=4, channel_x="chemical_shift",
                nucleus_type=self.nucleus_type,
            )
        return runs

    def to_mpgo(self, path: str | Path, features: list[str] | None = None) -> Path:
        runs = self.build_runs()
        return SpectralDataset.write_minimal(
            path,
            title=self.title or "imported",
            isa_investigation_id=self.isa_investigation_id,
            runs=runs,
            identifications=self.identifications or None,
            quantifications=self.quantifications or None,
            provenance=self.provenance or None,
            features=features,
        )


def _pack_run(
    spectra: list[ImportedSpectrum],
    *,
    spectrum_class: str,
    acquisition_mode: int,
    channel_x: str,
    nucleus_type: str = "",
) -> WrittenRun:
    n = len(spectra)
    lengths = np.array([s.mz_or_chemical_shift.shape[0] for s in spectra], dtype=np.uint32)
    offsets = np.zeros(n, dtype=np.uint64)
    if n > 0:
        offsets[1:] = np.cumsum(lengths[:-1], dtype=np.uint64)

    total = int(lengths.sum())
    x_buf = np.empty(total, dtype=np.float64)
    i_buf = np.empty(total, dtype=np.float64)
    pos = 0
    for s, length in zip(spectra, lengths):
        ln = int(length)
        x_buf[pos:pos + ln] = s.mz_or_chemical_shift
        i_buf[pos:pos + ln] = s.intensity
        pos += ln

    def _col(attr: str, dtype: type) -> np.ndarray:
        return np.array([getattr(s, attr) for s in spectra], dtype=dtype)

    base_peaks = np.array(
        [float(np.max(s.intensity)) if s.intensity.size else 0.0 for s in spectra],
        dtype=np.float64,
    )

    return WrittenRun(
        spectrum_class=spectrum_class,
        acquisition_mode=acquisition_mode,
        channel_data={channel_x: x_buf, "intensity": i_buf},
        offsets=offsets,
        lengths=lengths,
        retention_times=_col("retention_time", np.float64),
        ms_levels=_col("ms_level", np.int32),
        polarities=_col("polarity", np.int32),
        precursor_mzs=_col("precursor_mz", np.float64),
        precursor_charges=_col("precursor_charge", np.int32),
        base_peak_intensities=base_peaks,
        nucleus_type=nucleus_type,
    )
