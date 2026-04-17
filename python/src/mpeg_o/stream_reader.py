"""``StreamReader`` — sequential reader over a run inside an .mpgo file."""
from __future__ import annotations

import h5py

from .acquisition_run import AcquisitionRun
from .spectrum import Spectrum


class StreamReader:
    """Sequential reader for a single MS run inside an ``.mpgo`` file.

    Opens the file and the named run lazily; each
    :meth:`next_spectrum` call returns a :class:`Spectrum` via the
    run's hyperslab path. Suitable for streaming through runs larger
    than memory.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOStreamReader`` · Java:
    ``com.dtwthalion.mpgo.StreamReader``.
    """

    def __init__(self, file_path: str, run_name: str) -> None:
        self._file = h5py.File(file_path, "r")
        run_group_path = f"study/ms_runs/{run_name}"
        if run_group_path not in self._file:
            self._file.close()
            raise KeyError(f"run {run_name!r} not found in {file_path!r}")
        self._run = AcquisitionRun.open(self._file[run_group_path], name=run_name)

    @property
    def total_count(self) -> int:
        """Total number of spectra in the run."""
        return self._run.count()

    @property
    def current_position(self) -> int:
        """0-based position of the next spectrum to be read."""
        return self._run.current_position()

    def at_end(self) -> bool:
        """Return ``True`` once every spectrum has been read."""
        return not self._run.has_more()

    def next_spectrum(self) -> Spectrum:
        """Return the next spectrum and advance the cursor."""
        return self._run.next_object()

    def reset(self) -> None:
        """Reposition the cursor to 0."""
        self._run.reset()

    def close(self) -> None:
        """Close the underlying HDF5 file."""
        if self._file is not None:
            self._file.close()
            self._file = None

    def __enter__(self) -> "StreamReader":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
