"""JCAMP-DX 5.01 exporter for 1-D Raman, IR, and UV-Vis spectra.

Emits ``##XYDATA=(X++(Y..Y))`` in one of four forms selected by the
``encoding`` keyword:

- ``"affn"`` (default) — one ``(X, Y)`` pair per line, bit-accurate
  free-format floats via ``%.10g``. No YFACTOR scaling needed.
- ``"pac"`` / ``"sqz"`` / ``"dif"`` — JCAMP-DX 5.01 §5.9 compressed
  forms. Requires equispaced X (verified); picks a YFACTOR that
  carries ~7 significant digits of integer-scaled Y precision.
  Cross-language byte-parity-identical to the Java + ObjC writers,
  gated by the fixtures under ``conformance/jcamp_dx/``.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOJcampDxWriter`` · Java:
``global.thalion.ttio.exporters.JcampDxWriter``.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ..enums import IRMode
from ..ir_spectrum import IRSpectrum
from ..raman_spectrum import RamanSpectrum
from ..uv_vis_spectrum import UVVisSpectrum
from ._jcamp_encode import choose_yfactor, encode_xydata


_VALID_ENCODINGS = frozenset({"affn", "pac", "sqz", "dif"})


def _affn_xy(xs: np.ndarray, ys: np.ndarray) -> str:
    # ``%.10g`` matches the ObjC + Java AFFN writers precisely.
    out = ["##XYDATA=(X++(Y..Y))"]
    for x, y in zip(xs, ys):
        out.append(f"{x:.10g} {y:.10g}")
    return "\n".join(out) + "\n"


def _compressed_xy(xs: np.ndarray, ys: np.ndarray, encoding: str) -> tuple[str, float]:
    """Return (xydata_block, yfactor) for a PAC/SQZ/DIF encoding.

    Requires equispaced X. The returned block already contains the
    ``##XYDATA=`` label and a trailing newline.
    """
    n = int(xs.shape[0])
    if n < 2:
        raise ValueError(
            "JCAMP-DX compressed encoding requires NPOINTS >= 2"
        )
    firstx = float(xs[0])
    deltax = float(xs[-1] - xs[0]) / (n - 1)
    # Verify equispaced X within 1e-9 relative tolerance.
    expected = firstx + np.arange(n) * deltax
    max_abs = float(np.max(np.abs(expected))) if n else 0.0
    tol = max(1e-9 * max_abs, 1e-9)
    if not np.all(np.abs(xs - expected) <= tol):
        raise ValueError(
            "JCAMP-DX compressed encoding requires equispaced X"
        )
    yfactor = choose_yfactor(ys)
    body = encode_xydata(
        ys, firstx=firstx, deltax=deltax, yfactor=yfactor, mode=encoding,
    )
    return "##XYDATA=(X++(Y..Y))\n" + body, yfactor


def _render_xy(xs: np.ndarray, ys: np.ndarray, encoding: str) -> tuple[str, float]:
    """Return (xy_block, yfactor) for any supported encoding.

    AFFN always yields ``yfactor = 1.0`` — compressed paths may pick
    a different factor to carry Y precision through integer scaling.
    """
    if encoding == "affn":
        return _affn_xy(xs, ys), 1.0
    return _compressed_xy(xs, ys, encoding)


def _validate_encoding(encoding: str) -> str:
    enc = encoding.lower()
    if enc not in _VALID_ENCODINGS:
        raise ValueError(
            f"unknown JCAMP-DX encoding {encoding!r}; "
            f"expected one of {sorted(_VALID_ENCODINGS)}"
        )
    return enc


def write_raman_spectrum(
    spectrum: RamanSpectrum,
    path: str | Path,
    title: str = "",
    *,
    encoding: str = "affn",
) -> None:
    """Write ``spectrum`` to a JCAMP-DX 5.01 Raman file at ``path``.

    ``encoding`` ∈ ``{"affn", "pac", "sqz", "dif"}`` — the compressed
    forms require equispaced wavenumber sampling (M76).
    """
    enc = _validate_encoding(encoding)
    xs = np.asarray(spectrum.wavenumber_array.data, dtype=np.float64)
    ys = np.asarray(spectrum.intensity_array.data, dtype=np.float64)
    if xs.shape != ys.shape:
        raise ValueError(
            f"wavenumber/intensity length mismatch: "
            f"{xs.shape[0]} vs {ys.shape[0]}"
        )
    n = xs.shape[0]

    xy_block, yfactor = _render_xy(xs, ys, enc)

    parts = [
        f"##TITLE={title}",
        "##JCAMP-DX=5.01",
        "##DATA TYPE=RAMAN SPECTRUM",
        "##ORIGIN=TTI-O",
        "##OWNER=",
        "##XUNITS=1/CM",
        "##YUNITS=ARBITRARY UNITS",
        f"##FIRSTX={(xs[0] if n else 0.0):.10g}",
        f"##LASTX={(xs[-1] if n else 0.0):.10g}",
        f"##NPOINTS={n}",
        "##XFACTOR=1",
        f"##YFACTOR={yfactor:.10g}",
        f"##$EXCITATION WAVELENGTH NM={spectrum.excitation_wavelength_nm:.10g}",
        f"##$LASER POWER MW={spectrum.laser_power_mw:.10g}",
        f"##$INTEGRATION TIME SEC={spectrum.integration_time_sec:.10g}",
    ]
    body = "\n".join(parts) + "\n" + xy_block + "##END=\n"
    Path(path).write_text(body, encoding="utf-8")


def write_ir_spectrum(
    spectrum: IRSpectrum,
    path: str | Path,
    title: str = "",
    *,
    encoding: str = "affn",
) -> None:
    """Write ``spectrum`` to a JCAMP-DX 5.01 IR file at ``path``.

    ``encoding`` ∈ ``{"affn", "pac", "sqz", "dif"}`` — the compressed
    forms require equispaced wavenumber sampling (M76).
    """
    enc = _validate_encoding(encoding)
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

    xy_block, yfactor = _render_xy(xs, ys, enc)

    parts = [
        f"##TITLE={title}",
        "##JCAMP-DX=5.01",
        f"##DATA TYPE={data_type}",
        "##ORIGIN=TTI-O",
        "##OWNER=",
        "##XUNITS=1/CM",
        f"##YUNITS={y_units}",
        f"##FIRSTX={(xs[0] if n else 0.0):.10g}",
        f"##LASTX={(xs[-1] if n else 0.0):.10g}",
        f"##NPOINTS={n}",
        "##XFACTOR=1",
        f"##YFACTOR={yfactor:.10g}",
        f"##RESOLUTION={spectrum.resolution_cm_inv:.10g}",
        f"##$NUMBER OF SCANS={spectrum.number_of_scans}",
    ]
    body = "\n".join(parts) + "\n" + xy_block + "##END=\n"
    Path(path).write_text(body, encoding="utf-8")


def write_uv_vis_spectrum(
    spectrum: UVVisSpectrum,
    path: str | Path,
    title: str = "",
    *,
    encoding: str = "affn",
) -> None:
    """Write ``spectrum`` to a JCAMP-DX 5.01 UV/VIS file at ``path``.

    ``encoding`` ∈ ``{"affn", "pac", "sqz", "dif"}`` — the compressed
    forms require equispaced wavelength sampling (M76).
    """
    enc = _validate_encoding(encoding)
    xs = np.asarray(spectrum.wavelength_array.data, dtype=np.float64)
    ys = np.asarray(spectrum.absorbance_array.data, dtype=np.float64)
    if xs.shape != ys.shape:
        raise ValueError(
            f"wavelength/absorbance length mismatch: "
            f"{xs.shape[0]} vs {ys.shape[0]}"
        )
    n = xs.shape[0]

    xy_block, yfactor = _render_xy(xs, ys, enc)

    parts = [
        f"##TITLE={title}",
        "##JCAMP-DX=5.01",
        "##DATA TYPE=UV/VIS SPECTRUM",
        "##ORIGIN=TTI-O",
        "##OWNER=",
        "##XUNITS=NANOMETERS",
        "##YUNITS=ABSORBANCE",
        f"##FIRSTX={(xs[0] if n else 0.0):.10g}",
        f"##LASTX={(xs[-1] if n else 0.0):.10g}",
        f"##NPOINTS={n}",
        "##XFACTOR=1",
        f"##YFACTOR={yfactor:.10g}",
        f"##$PATH LENGTH CM={spectrum.path_length_cm:.10g}",
        f"##$SOLVENT={spectrum.solvent}",
    ]
    body = "\n".join(parts) + "\n" + xy_block + "##END=\n"
    Path(path).write_text(body, encoding="utf-8")


__all__ = ["write_raman_spectrum", "write_ir_spectrum", "write_uv_vis_spectrum"]
