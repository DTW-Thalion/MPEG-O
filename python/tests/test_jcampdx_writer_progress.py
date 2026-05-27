"""ProgressSink coverage for JCAMP-DX writers."""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio.axis_descriptor import AxisDescriptor
from ttio.enums import IRMode
from ttio.exporters.jcamp_dx import (
    write_ir_spectrum,
    write_raman_spectrum,
    write_uv_vis_spectrum,
)
from ttio.ir_spectrum import IRSpectrum
from ttio.raman_spectrum import RamanSpectrum
from ttio.signal_array import SignalArray
from ttio.uv_vis_spectrum import UVVisSpectrum


def _signal(values: list[float], name: str, unit: str) -> SignalArray:
    return SignalArray.from_numpy(
        np.asarray(values, dtype=np.float64),
        axis=AxisDescriptor(name=name, unit=unit),
    )


def test_jcampdx_raman_writer_progress(tmp_path: Path) -> None:
    spec = RamanSpectrum(
        signal_arrays={
            RamanSpectrum.WAVENUMBER: _signal([100.0, 200.0, 300.0],
                                               "wavenumber", "1/cm"),
            RamanSpectrum.INTENSITY: _signal([1.0, 2.0, 3.0],
                                              "intensity", ""),
        },
    )
    events: list[tuple[int, int]] = []
    write_raman_spectrum(
        spec, tmp_path / "raman.jdx",
        progress=lambda d, t: events.append((d, t)),
    )
    assert events == [(1, 1)]


def test_jcampdx_ir_writer_progress(tmp_path: Path) -> None:
    spec = IRSpectrum(
        signal_arrays={
            IRSpectrum.WAVENUMBER: _signal([100.0, 200.0, 300.0],
                                           "wavenumber", "1/cm"),
            IRSpectrum.INTENSITY: _signal([1.0, 2.0, 3.0],
                                          "intensity", ""),
        },
        mode=IRMode.ABSORBANCE,
    )
    events: list[tuple[int, int]] = []
    write_ir_spectrum(
        spec, tmp_path / "ir.jdx",
        progress=lambda d, t: events.append((d, t)),
    )
    assert events == [(1, 1)]


def test_jcampdx_uv_vis_writer_progress(tmp_path: Path) -> None:
    spec = UVVisSpectrum(
        signal_arrays={
            UVVisSpectrum.WAVELENGTH: _signal([400.0, 500.0, 600.0],
                                              "wavelength", "nm"),
            UVVisSpectrum.ABSORBANCE: _signal([0.1, 0.2, 0.3],
                                              "absorbance", ""),
        },
    )
    events: list[tuple[int, int]] = []
    write_uv_vis_spectrum(
        spec, tmp_path / "uvvis.jdx",
        progress=lambda d, t: events.append((d, t)),
    )
    assert events == [(1, 1)]
