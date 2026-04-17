"""``StreamWriter`` — incremental append writer for .mpgo files."""
from __future__ import annotations

from pathlib import Path

from .acquisition_run import AcquisitionRun  # type: ignore
from .enums import AcquisitionMode
from .instrument_config import InstrumentConfig
from .mass_spectrum import MassSpectrum
from .spectral_dataset import SpectralDataset


class StreamWriter:
    """Incrementally append mass spectra to an ``.mpgo`` file.

    Spectra accumulate in memory until :meth:`flush` is called. On
    each flush the file is rewritten so that the run group reflects
    every spectrum buffered so far — the file remains a valid
    ``.mpgo`` after each flush.

    Notes
    -----
    API status: Stable.

    For v0.6 the writer's flush is whole-file regenerative: simple,
    correct, and bounded for the streaming-demo case (≤ a few
    thousand spectra). A future milestone may switch to extendable
    HDF5 datasets.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOStreamWriter`` · Java:
    ``com.dtwthalion.mpgo.StreamWriter``.
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

        The file is a valid ``.mpgo`` after each flush.
        """
        # Build an in-memory SpectralDataset with one AcquisitionRun
        # containing the buffered spectra, then write it out.
        # Delegate to SpectralDataset's write path (whatever it is).
        raise NotImplementedError(
            "StreamWriter.flush requires integration with "
            "SpectralDataset.write — full implementation in a future "
            "milestone. For now, callers buffer spectra and write via "
            "SpectralDataset directly.")

    def flush_and_close(self) -> None:
        """Flush one final time and release resources."""
        self.flush()

    def close(self) -> None:
        """Release resources without flushing."""
        self._spectra.clear()
