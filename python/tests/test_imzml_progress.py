"""ProgressSink coverage for :func:`ttio.importers.imzml.read`.

Builds a synthetic 250-pixel continuous-mode imzML via the writer,
then asserts the reader fires progress every PROGRESS_INTERVAL_SPECTRA
pixels during the .ibd materialise loop.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio.exporters import imzml as imzml_writer
from ttio.importers.imzml import PROGRESS_INTERVAL_SPECTRA, ImzMLPixelSpectrum, read


def _build_synth_imzml(path: Path, n: int) -> None:
    mz = np.linspace(100.0, 900.0, 16)
    pixels = [
        ImzMLPixelSpectrum(
            x=i % 25 + 1,
            y=i // 25 + 1,
            z=1,
            mz=mz,
            intensity=np.full(16, float(i)),
        )
        for i in range(n)
    ]
    imzml_writer.write(
        pixels, path,
        mode="continuous",
        grid_max_x=25, grid_max_y=10,
        pixel_size_x=10.0, pixel_size_y=10.0,
    )


def test_imzml_progress_fires_per_interval(tmp_path: Path) -> None:
    n = 250
    p = tmp_path / "synth.imzML"
    _build_synth_imzml(p, n)

    events: list[tuple[int, int]] = []
    imp = read(p, progress=lambda d, t: events.append((d, t)))
    assert len(imp.spectra) == n
    assert len(events) >= n // PROGRESS_INTERVAL_SPECTRA, events
    assert events[-1] == (n, n)
    assert any(t == -1 for _, t in events[:-1])


def test_imzml_progress_none_safe(tmp_path: Path) -> None:
    n = 50
    p = tmp_path / "tiny.imzML"
    _build_synth_imzml(p, n)
    imp = read(p)
    assert len(imp.spectra) == n
