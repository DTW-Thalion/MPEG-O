"""ProgressSink coverage for :func:`ttio.exporters.mzml.write_dataset`."""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio.exporters.mzml import PROGRESS_INTERVAL_SPECTRA, write_dataset
from ttio.spectral_dataset import SpectralDataset, WrittenRun


def _make_dataset_with_n_spectra(n: int) -> tuple[Path, SpectralDataset]:
    raise NotImplementedError  # not used; see helper below


def _build_run(n: int) -> WrittenRun:
    n_points = 4
    lengths = np.full(n, n_points, dtype=np.uint32)
    offsets = np.arange(0, n * n_points, n_points, dtype=np.uint64)
    mz_data = np.tile(np.arange(n_points, dtype=np.float64), n)
    int_data = np.tile(np.arange(n_points, dtype=np.float64), n)
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz_data, "intensity": int_data},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.arange(n, dtype=np.float64),
        ms_levels=np.ones(n, dtype=np.uint8),
        polarities=np.zeros(n, dtype=np.int8),
        precursor_mzs=np.zeros(n, dtype=np.float64),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=np.zeros(n, dtype=np.float64),
    )


def test_mzml_writer_progress(tmp_path: Path) -> None:
    n = 250
    tio = tmp_path / "in.tio"
    SpectralDataset.write_minimal(
        tio, title="t", isa_investigation_id="",
        runs={"run_0001": _build_run(n)},
    )
    out = tmp_path / "out.mzML"
    with SpectralDataset.open(tio) as ds:
        events: list[tuple[int, int]] = []
        write_dataset(ds, out, progress=lambda d, t: events.append((d, t)))
    assert len(events) >= n // PROGRESS_INTERVAL_SPECTRA
    assert events[-1] == (n, n)
