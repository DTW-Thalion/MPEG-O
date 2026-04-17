"""nmrML writer — Milestone 29.

Serializes an :class:`mpeg_o.NMRSpectrum` (and optionally its FID) to
an nmrML XML document. Output mirrors the elements parsed by
``mpeg_o.importers.nmrml`` so it round-trips through the reader.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import base64
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from ..fid import FreeInductionDecay
    from ..nmr_spectrum import NMRSpectrum


def _encode(arr: np.ndarray) -> str:
    return base64.b64encode(
        np.ascontiguousarray(arr, dtype="<f8").tobytes()
    ).decode("ascii")


def _fmt(v: float) -> str:
    return f"{v:.15g}"


def spectrum_to_bytes(
    spectrum: "NMRSpectrum",
    *,
    fid: "FreeInductionDecay | None" = None,
    sweep_width_ppm: float = 0.0,
) -> bytes:
    """Build an nmrML byte blob from ``spectrum`` + optional ``fid``."""
    parts: list[str] = []

    def emit(s: str) -> None:
        parts.append(s)

    emit('<?xml version="1.0" encoding="UTF-8"?>\n')
    emit('<nmrML xmlns="http://nmrml.org/schema"'
         ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
         ' xsi:schemaLocation="http://nmrml.org/schema'
         ' http://nmrml.org/schema/v1.0/nmrML.xsd">\n')

    emit('  <cvList>\n')
    emit('    <cv id="nmrCV" fullName="nmrML Controlled Vocabulary"'
         ' version="1.1.0" URI="http://nmrml.org/cv/v1.1.0/nmrCV.owl"/>\n')
    emit('  </cvList>\n')

    emit('  <acquisition>\n')
    emit('    <acquisition1D>\n')
    emit('      <acquisitionParameterSet numberOfScans="1">\n')

    nucleus = spectrum.nucleus_type if hasattr(spectrum, "nucleus_type") else ""
    freq_mhz = 0.0
    if hasattr(spectrum, "signal_arrays") and "chemical_shift" in spectrum.signal_arrays:
        pass  # freq comes from the run, not the spectrum
    emit(f'        <acquisitionNucleus name="{nucleus}"/>\n')

    # spectrometer frequency: stored in MHz, nmrML expects Hz
    freq_hz = freq_mhz * 1.0e6
    emit(f'        <cvParam cvRef="nmrCV" accession="NMR:1000001"'
         f' name="spectrometer frequency" value="{_fmt(freq_hz)}"/>\n')
    emit(f'        <cvParam cvRef="nmrCV" accession="NMR:1000002"'
         f' name="acquisition nucleus" value="{nucleus}"/>\n')

    if sweep_width_ppm > 0.0:
        emit(f'        <cvParam cvRef="nmrCV" accession="NMR:1400014"'
             f' name="sweep width" value="{_fmt(sweep_width_ppm)}"/>\n')

    if fid is not None:
        emit(f'        <cvParam cvRef="nmrCV" accession="NMR:1000004"'
             f' name="dwell time" value="{_fmt(fid.dwell_time_seconds)}"/>\n')

    emit('      </acquisitionParameterSet>\n')

    if fid is not None:
        fid_b64 = base64.b64encode(
            np.ascontiguousarray(fid.data, dtype="<f8").tobytes()
        ).decode("ascii")
        emit(f'      <fidData compressed="false" byteFormat="float64"'
             f' encodedLength="{len(fid_b64)}">\n')
        emit(f'        {fid_b64}\n')
        emit('      </fidData>\n')

    emit('    </acquisition1D>\n')
    emit('  </acquisition>\n')

    # spectrum1D
    emit('  <spectrumList>\n')
    emit('    <spectrum1D>\n')

    cs_data = spectrum.signal_arrays["chemical_shift"].data
    int_data = spectrum.signal_arrays["intensity"].data
    x_b64 = _encode(cs_data)
    y_b64 = _encode(int_data)

    emit('      <xAxis>\n')
    emit(f'        <spectrumDataArray compressed="false"'
         f' encodedLength="{len(x_b64)}">\n')
    emit(f'          {x_b64}\n')
    emit('        </spectrumDataArray>\n')
    emit('      </xAxis>\n')

    emit('      <yAxis>\n')
    emit(f'        <spectrumDataArray compressed="false"'
         f' encodedLength="{len(y_b64)}">\n')
    emit(f'          {y_b64}\n')
    emit('        </spectrumDataArray>\n')
    emit('      </yAxis>\n')

    emit('    </spectrum1D>\n')
    emit('  </spectrumList>\n')
    emit('</nmrML>\n')

    return "".join(parts).encode("utf-8")


def write_spectrum(
    spectrum: "NMRSpectrum",
    path: str | Path,
    *,
    fid: "FreeInductionDecay | None" = None,
    sweep_width_ppm: float = 0.0,
) -> Path:
    blob = spectrum_to_bytes(spectrum, fid=fid, sweep_width_ppm=sweep_width_ppm)
    out = Path(path)
    out.write_bytes(blob)
    return out
