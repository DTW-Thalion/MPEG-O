"""JCAMP-DX 5.01 reader for 1-D vibrational and UV-Vis spectra.

Dispatches on ``##DATA TYPE=`` and returns one of
:class:`RamanSpectrum`, :class:`IRSpectrum`, or :class:`UVVisSpectrum`.

Accepts two dialects of ``##XYDATA=(X++(Y..Y))``:

- **AFFN** (fast path) — one ``(X, Y)`` pair per line, free-format
  decimals. Emitted by :mod:`ttio.exporters.jcamp_dx`. Preserves
  non-uniform X spacing verbatim.
- **PAC / SQZ / DIF / DUP** (compressed) — JCAMP-DX 5.01 §5.9
  character-encoded Y-stream. Delegated to
  :func:`_jcamp_decode.decode_xydata`. Requires ``FIRSTX``, ``LASTX``,
  and ``NPOINTS`` headers (equispaced X).

Cross-language equivalents
--------------------------
Objective-C: ``TTIOJcampDxReader`` · Java:
``global.thalion.ttio.importers.JcampDxReader``.
"""
from __future__ import annotations

from pathlib import Path
from typing import Union

import numpy as np

from ..axis_descriptor import AxisDescriptor
from ..enums import IRMode
from ..ir_spectrum import IRSpectrum
from ..raman_spectrum import RamanSpectrum
from ..signal_array import SignalArray
from ..uv_vis_spectrum import UVVisSpectrum
from ._jcamp_decode import decode_xydata, has_compression


Spectrum1D = Union[RamanSpectrum, IRSpectrum, UVVisSpectrum]


def _make_signal(values: list[float], axis_name: str, unit: str) -> SignalArray:
    return SignalArray.from_numpy(
        np.asarray(values, dtype=np.float64),
        axis=AxisDescriptor(name=axis_name, unit=unit),
    )


def _parse_ldrs_and_body(text: str) -> tuple[dict[str, str], str]:
    """Split the file into (header LDR map, raw XYDATA body text).

    The XYDATA body is everything between the ``##XYDATA=`` label and
    either ``##END=`` or the next LDR.
    """
    ldrs: dict[str, str] = {}
    body_lines: list[str] = []
    in_xydata = False

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("##"):
            in_xydata = False
            eq = line.find("=")
            if eq < 0:
                continue
            label = line[2:eq].strip()
            value = line[eq + 1:].strip()
            ldrs[label] = value
            if label == "XYDATA":
                in_xydata = True
            elif label == "END":
                break
            continue
        if in_xydata:
            body_lines.append(raw)

    return ldrs, "\n".join(body_lines)


def _parse_xy(ldrs: dict[str, str], body: str) -> tuple[list[float], list[float]]:
    """Return (xs, ys) from the XYDATA body, choosing AFFN or compressed."""
    xfactor = float(ldrs.get("XFACTOR", "1") or 1)
    yfactor = float(ldrs.get("YFACTOR", "1") or 1)

    if has_compression(body):
        try:
            firstx = float(ldrs["FIRSTX"])
            lastx = float(ldrs["LASTX"])
            npoints = int(float(ldrs["NPOINTS"]))
        except (KeyError, ValueError) as exc:
            raise ValueError(
                "JCAMP-DX: compressed XYDATA requires FIRSTX / LASTX / NPOINTS"
            ) from exc
        if npoints < 2:
            raise ValueError("JCAMP-DX: NPOINTS must be >= 2 for compressed data")
        deltax = (lastx - firstx) / (npoints - 1)
        return decode_xydata(
            body.splitlines(),
            firstx=firstx,
            deltax=deltax,
            xfactor=xfactor,
            yfactor=yfactor,
        )

    # AFFN fast path: one (X, Y) pair per line.
    xs: list[float] = []
    ys: list[float] = []
    for raw in body.splitlines():
        line = raw.strip()
        if not line:
            continue
        toks = [t for t in line.split() if t]
        if not toks:
            continue
        try:
            nums = [float(t) for t in toks]
        except ValueError:
            continue
        if len(nums) >= 2:
            xs.append(nums[0] * xfactor)
            ys.append(nums[1] * yfactor)
        elif len(nums) == 1 and len(xs) == len(ys) + 1:
            ys.append(nums[0] * yfactor)
    return xs, ys


def read_spectrum(path: str | Path) -> Spectrum1D:
    """Parse ``path`` and return an appropriate spectrum subclass.

    Raises
    ------
    ValueError
        If the file is malformed (empty/mismatched XYDATA) or carries a
        ``##DATA TYPE=`` that this reader does not handle.
    """
    text = Path(path).read_text(encoding="utf-8")
    ldrs, body = _parse_ldrs_and_body(text)

    xs, ys = _parse_xy(ldrs, body)
    if len(xs) != len(ys) or len(xs) == 0:
        raise ValueError("JCAMP-DX: empty or mismatched XYDATA")

    data_type = ldrs.get("DATA TYPE", "").upper()

    # UV-Vis takes wavelength (nm) on the X axis, not wavenumber.
    if data_type in {"UV/VIS SPECTRUM", "UV-VIS SPECTRUM", "UV/VISIBLE SPECTRUM"}:
        x_signal = _make_signal(xs, "wavelength", "nm")
        y_signal = _make_signal(ys, "absorbance", "")
        return UVVisSpectrum(
            signal_arrays={
                UVVisSpectrum.WAVELENGTH: x_signal,
                UVVisSpectrum.ABSORBANCE: y_signal,
            },
            path_length_cm=float(ldrs.get("$PATH LENGTH CM", "0") or 0),
            solvent=ldrs.get("$SOLVENT", "") or "",
        )

    x_signal = _make_signal(xs, "wavenumber", "1/cm")
    y_signal = _make_signal(ys, "intensity", "")

    if data_type == "RAMAN SPECTRUM":
        return RamanSpectrum(
            signal_arrays={
                RamanSpectrum.WAVENUMBER: x_signal,
                RamanSpectrum.INTENSITY: y_signal,
            },
            excitation_wavelength_nm=float(
                ldrs.get("$EXCITATION WAVELENGTH NM", "0") or 0
            ),
            laser_power_mw=float(ldrs.get("$LASER POWER MW", "0") or 0),
            integration_time_sec=float(
                ldrs.get("$INTEGRATION TIME SEC", "0") or 0
            ),
        )

    if data_type in {
        "INFRARED ABSORBANCE",
        "INFRARED TRANSMITTANCE",
        "INFRARED SPECTRUM",
    }:
        if data_type == "INFRARED ABSORBANCE":
            mode = IRMode.ABSORBANCE
        elif data_type == "INFRARED TRANSMITTANCE":
            mode = IRMode.TRANSMITTANCE
        else:
            y_units = ldrs.get("YUNITS", "").upper()
            mode = IRMode.ABSORBANCE if "ABSORB" in y_units else IRMode.TRANSMITTANCE
        resolution = float(ldrs.get("RESOLUTION", "0") or 0)
        scans = int(float(ldrs.get("$NUMBER OF SCANS", "0") or 0))
        return IRSpectrum(
            signal_arrays={
                IRSpectrum.WAVENUMBER: x_signal,
                IRSpectrum.INTENSITY: y_signal,
            },
            mode=mode,
            resolution_cm_inv=resolution,
            number_of_scans=scans,
        )

    raise ValueError(f"JCAMP-DX: unsupported DATA TYPE={ldrs.get('DATA TYPE', '')!r}")


__all__ = ["read_spectrum"]
