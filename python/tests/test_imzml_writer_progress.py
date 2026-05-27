"""ProgressSink coverage for :func:`ttio.exporters.imzml.write`."""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio.exporters.imzml import PROGRESS_INTERVAL_SPECTRA, write
from ttio.importers.imzml import ImzMLPixelSpectrum


def test_imzml_writer_progress(tmp_path: Path) -> None:
    n = 250
    mz = np.linspace(100.0, 900.0, 16)
    pixels = [
        ImzMLPixelSpectrum(
            x=i % 25 + 1, y=i // 25 + 1, z=1,
            mz=mz, intensity=np.full(16, float(i)),
        )
        for i in range(n)
    ]
    events: list[tuple[int, int]] = []
    write(
        pixels, tmp_path / "out.imzML",
        mode="continuous",
        grid_max_x=25, grid_max_y=10,
        pixel_size_x=10.0, pixel_size_y=10.0,
        progress=lambda d, t: events.append((d, t)),
    )
    assert len(events) >= n // PROGRESS_INTERVAL_SPECTRA, events
    assert events[-1] == (n, n)
