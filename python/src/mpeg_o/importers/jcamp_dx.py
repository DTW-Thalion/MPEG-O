"""JCAMP-DX 5.01 reader for 1-D vibrational spectra.

Dispatches on ``##DATA TYPE=`` and returns a :class:`RamanSpectrum` or
:class:`IRSpectrum`. Accepts the AFFN ``##XYDATA=(X++(Y..Y))`` dialect
emitted by :mod:`mpeg_o.exporters.jcamp_dx` and the more permissive
"one (X, Y) pair per line" variant. PAC / SQZ / DIF compression is not
supported in M73.

Cross-language equivalents
--------------------------
Objective-C: ``MPGOJcampDxReader`` · Java:
``com.dtwthalion.mpgo.importers.JcampDxReader``.
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


Spectrum1D = Union[RamanSpectrum, IRSpectrum]


def _make_signal(values: list[float], axis_name: str, unit: str) -> SignalArray:
    return SignalArray.from_numpy(
        np.asarray(values, dtype=np.float64),
        axis=AxisDescriptor(name=axis_name, unit=unit),
    )


def read_spectrum(path: str | Path) -> Spectrum1D:
    """Parse ``path`` and return an appropriate spectrum subclass.

    Raises
    ------
    ValueError
        If the file is malformed (empty/mismatched XYDATA) or carries a
        ``##DATA TYPE=`` that this reader does not handle.
    """
    text = Path(path).read_text(encoding="utf-8")
    ldrs: dict[str, str] = {}
    xs: list[float] = []
    ys: list[float] = []
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
            toks = [t for t in line.split() if t]
            if not toks:
                continue
            try:
                nums = [float(t) for t in toks]
            except ValueError:
                continue
            if len(nums) >= 2:
                xs.append(nums[0])
                ys.append(nums[1])
            elif len(nums) == 1 and len(xs) == len(ys) + 1:
                ys.append(nums[0])

    if len(xs) != len(ys) or len(xs) == 0:
        raise ValueError("JCAMP-DX: empty or mismatched XYDATA")

    data_type = ldrs.get("DATA TYPE", "").upper()
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
