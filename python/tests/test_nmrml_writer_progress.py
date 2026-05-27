"""ProgressSink coverage for :func:`ttio.exporters.nmrml.write_spectrum`."""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio.axis_descriptor import AxisDescriptor
from ttio.exporters.nmrml import write_spectrum
from ttio.nmr_spectrum import NMRSpectrum
from ttio.signal_array import SignalArray


def _build_spectrum() -> NMRSpectrum:
    xs = np.linspace(0.0, 10.0, 16)
    ys = np.linspace(1.0, 100.0, 16)
    return NMRSpectrum(
        signal_arrays={
            "chemical_shift": SignalArray.from_numpy(
                xs, axis=AxisDescriptor(name="chemical_shift", unit="ppm"),
            ),
            "intensity": SignalArray.from_numpy(
                ys, axis=AxisDescriptor(name="intensity", unit=""),
            ),
        },
        nucleus_type="1H",
    )


def test_nmrml_writer_progress_fires_once(tmp_path: Path) -> None:
    spec = _build_spectrum()
    out = tmp_path / "out.nmrML"
    events: list[tuple[int, int]] = []
    write_spectrum(spec, out, progress=lambda d, t: events.append((d, t)))
    assert events == [(1, 1)]
