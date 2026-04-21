"""JCAMP-DX 5.01 exporter for 1-D Raman and IR spectra.

Emits AFFN ``##XYDATA=(X++(Y..Y))`` with one ``(X, Y)`` pair per line.
PAC / SQZ / DIF compression is intentionally not produced — the reader
matched here does not accept it either. 2-D NTUPLES form is out of
scope for v0.11 (tracked under M73.1).

Cross-language equivalents
--------------------------
Objective-C: ``MPGOJcampDxWriter`` · Java:
``com.dtwthalion.mpgo.exporters.JcampDxWriter``.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ..enums import IRMode
from ..ir_spectrum import IRSpectrum
from ..raman_spectrum import RamanSpectrum


def _format_xy(xs: np.ndarray, ys: np.ndarray) -> str:
    # ``%.10g`` matches the ObjC writer precisely.
    out = ["##XYDATA=(X++(Y..Y))"]
    for x, y in zip(xs, ys):
        out.append(f"{x:.10g} {y:.10g}")
    return "\n".join(out) + "\n"


def write_raman_spectrum(
    spectrum: RamanSpectrum,
    path: str | Path,
    title: str = "",
) -> None:
    """Write ``spectrum`` to a JCAMP-DX 5.01 Raman file at ``path``."""
    xs = np.asarray(spectrum.wavenumber_array.data, dtype=np.float64)
    ys = np.asarray(spectrum.intensity_array.data, dtype=np.float64)
    if xs.shape != ys.shape:
        raise ValueError(
            f"wavenumber/intensity length mismatch: "
            f"{xs.shape[0]} vs {ys.shape[0]}"
        )
    n = xs.shape[0]

    parts = [
        f"##TITLE={title}",
        "##JCAMP-DX=5.01",
        "##DATA TYPE=RAMAN SPECTRUM",
        "##ORIGIN=MPEG-O",
        "##OWNER=",
        "##XUNITS=1/CM",
        "##YUNITS=ARBITRARY UNITS",
        f"##FIRSTX={(xs[0] if n else 0.0):.10g}",
        f"##LASTX={(xs[-1] if n else 0.0):.10g}",
        f"##NPOINTS={n}",
        "##XFACTOR=1",
        "##YFACTOR=1",
        f"##$EXCITATION WAVELENGTH NM={spectrum.excitation_wavelength_nm:.10g}",
        f"##$LASER POWER MW={spectrum.laser_power_mw:.10g}",
        f"##$INTEGRATION TIME SEC={spectrum.integration_time_sec:.10g}",
    ]
    body = "\n".join(parts) + "\n" + _format_xy(xs, ys) + "##END=\n"
    Path(path).write_text(body, encoding="utf-8")


def write_ir_spectrum(
    spectrum: IRSpectrum,
    path: str | Path,
    title: str = "",
) -> None:
    """Write ``spectrum`` to a JCAMP-DX 5.01 IR file at ``path``."""
    xs = np.asarray(spectrum.wavenumber_array.data, dtype=np.float64)
    ys = np.asarray(spectrum.intensity_array.data, dtype=np.float64)
    if xs.shape != ys.shape:
        raise ValueError(
            f"wavenumber/intensity length mismatch: "
            f"{xs.shape[0]} vs {ys.shape[0]}"
        )
    n = xs.shape[0]

    if spectrum.mode == IRMode.ABSORBANCE:
        data_type = "INFRARED ABSORBANCE"
        y_units = "ABSORBANCE"
    else:
        data_type = "INFRARED TRANSMITTANCE"
        y_units = "TRANSMITTANCE"

    parts = [
        f"##TITLE={title}",
        "##JCAMP-DX=5.01",
        f"##DATA TYPE={data_type}",
        "##ORIGIN=MPEG-O",
        "##OWNER=",
        "##XUNITS=1/CM",
        f"##YUNITS={y_units}",
        f"##FIRSTX={(xs[0] if n else 0.0):.10g}",
        f"##LASTX={(xs[-1] if n else 0.0):.10g}",
        f"##NPOINTS={n}",
        "##XFACTOR=1",
        "##YFACTOR=1",
        f"##RESOLUTION={spectrum.resolution_cm_inv:.10g}",
        f"##$NUMBER OF SCANS={spectrum.number_of_scans}",
    ]
    body = "\n".join(parts) + "\n" + _format_xy(xs, ys) + "##END=\n"
    Path(path).write_text(body, encoding="utf-8")


__all__ = ["write_raman_spectrum", "write_ir_spectrum"]
