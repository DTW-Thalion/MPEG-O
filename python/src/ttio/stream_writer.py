"""``StreamWriter`` — incremental append writer for .tio files."""
from __future__ import annotations

from pathlib import Path

from .acquisition_run import AcquisitionRun  # type: ignore
from .enums import AcquisitionMode
from .instrument_config import InstrumentConfig
from .mass_spectrum import MassSpectrum
from .spectral_dataset import SpectralDataset


class StreamWriter:
    """Incrementally append mass spectra to an ``.tio`` file.

    Spectra accumulate in memory until :meth:`flush` is called. On
    each flush the file is rewritten so that the run group reflects
    every spectrum buffered so far — the file remains a valid
    ``.tio`` after each flush.

    Notes
    -----
    API status: Stable.

    For v0.6 the writer's flush is whole-file regenerative: simple,
    correct, and bounded for the streaming-demo case (≤ a few
    thousand spectra). A future milestone may switch to extendable
    HDF5 datasets.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOStreamWriter`` · Java:
    ``com.dtwthalion.ttio.StreamWriter``.
    """

    def __init__(self, file_path: str,
                 run_name: str,
                 acquisition_mode: AcquisitionMode,
                 instrument_config: InstrumentConfig) -> None:
        self._path = Path(file_path)
        self._run_name = run_name
        self._acquisition_mode = acquisition_mode
        self._instrument_config = instrument_config
        self._spectra: list[MassSpectrum] = []

    def append_spectrum(self, spectrum: MassSpectrum) -> None:
        """Buffer a spectrum. Call :meth:`flush` to persist."""
        self._spectra.append(spectrum)

    @property
    def spectrum_count(self) -> int:
        """Number of buffered spectra."""
        return len(self._spectra)

    def flush(self) -> None:
        """Rewrite the target file with all buffered spectra so far.

        Converts each buffered :class:`~ttio.mass_spectrum.MassSpectrum`
        into an :class:`~ttio.importers.import_result.ImportedSpectrum`,
        packs them into a :class:`~ttio.spectral_dataset.WrittenRun`, and
        delegates to :meth:`~ttio.spectral_dataset.SpectralDataset.write_minimal`
        so the target file is a valid ``.tio`` after each call.
        """
        import numpy as np
        from .importers.import_result import ImportedSpectrum, _pack_run
        from .spectral_dataset import SpectralDataset

        imported = [
            ImportedSpectrum(
                mz_or_chemical_shift=ms.mz_array.data,
                intensity=ms.intensity_array.data,
                retention_time=ms.scan_time_seconds,
                ms_level=ms.ms_level,
                polarity=int(ms.polarity),
                precursor_mz=ms.precursor_mz,
                precursor_charge=ms.precursor_charge,
            )
            for ms in self._spectra
        ]

        if imported:
            written_run = _pack_run(
                imported,
                spectrum_class="TTIOMassSpectrum",
                acquisition_mode=int(self._acquisition_mode),
                channel_x="mz",
            )
        else:
            from .spectral_dataset import WrittenRun
            written_run = WrittenRun(
                spectrum_class="TTIOMassSpectrum",
                acquisition_mode=int(self._acquisition_mode),
                channel_data={"mz": np.zeros(0, dtype=np.float64),
                              "intensity": np.zeros(0, dtype=np.float64)},
                offsets=np.zeros(0, dtype=np.uint64),
                lengths=np.zeros(0, dtype=np.uint32),
                retention_times=np.zeros(0, dtype=np.float64),
                ms_levels=np.zeros(0, dtype=np.int32),
                polarities=np.zeros(0, dtype=np.int32),
                precursor_mzs=np.zeros(0, dtype=np.float64),
                precursor_charges=np.zeros(0, dtype=np.int32),
                base_peak_intensities=np.zeros(0, dtype=np.float64),
            )

        SpectralDataset.write_minimal(
            self._path,
            title="",
            isa_investigation_id="",
            runs={self._run_name: written_run},
        )

    def flush_and_close(self) -> None:
        """Flush one final time and release resources."""
        self.flush()

    def close(self) -> None:
        """Release resources without flushing."""
        self._spectra.clear()
