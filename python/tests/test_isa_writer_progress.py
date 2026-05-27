"""ProgressSink coverage for :func:`ttio.exporters.isa.write_bundle_for_dataset`."""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio.exporters.isa import bundle_for_dataset, write_bundle_for_dataset
from ttio.spectral_dataset import SpectralDataset, WrittenRun


def _build_run() -> WrittenRun:
    n = 3
    n_points = 2
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=0,
        channel_data={
            "mz": np.tile(np.arange(n_points, dtype=np.float64), n),
            "intensity": np.tile(np.arange(n_points, dtype=np.float64), n),
        },
        offsets=np.arange(0, n * n_points, n_points, dtype=np.uint64),
        lengths=np.full(n, n_points, dtype=np.uint32),
        retention_times=np.arange(n, dtype=np.float64),
        ms_levels=np.ones(n, dtype=np.uint8),
        polarities=np.zeros(n, dtype=np.int8),
        precursor_mzs=np.zeros(n, dtype=np.float64),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=np.zeros(n, dtype=np.float64),
    )


def test_isa_writer_progress(tmp_path: Path) -> None:
    tio = tmp_path / "in.tio"
    SpectralDataset.write_minimal(
        tio, title="t", isa_investigation_id="",
        runs={"run_0001": _build_run()},
    )
    out_dir = tmp_path / "isa"
    events: list[tuple[int, int]] = []
    with SpectralDataset.open(tio) as ds:
        bundle = bundle_for_dataset(ds)
        expected_total = len(bundle)
        write_bundle_for_dataset(
            ds, out_dir,
            progress=lambda d, t: events.append((d, t)),
        )
    assert events, "expected at least one progress callback"
    assert events[-1] == (expected_total, expected_total)
