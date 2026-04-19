"""nmrML writer — Milestone 29.

Serializes an :class:`mpeg_o.NMRSpectrum` (and optionally its FID) to
an nmrML XML document. Output mirrors the elements parsed by
``mpeg_o.importers.nmrml`` so it round-trips through the reader.

SPDX-License-Identifier: Apache-2.0

Cross-language equivalents
--------------------------
Objective-C: ``MPGONmrMLWriter`` · Java:
``com.dtwthalion.mpgo.exporters.NmrMLWriter``

API status: Stable.
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
    spectrometer_frequency_mhz: float = 0.0,
) -> bytes:
    """Build an nmrML byte blob from ``spectrum`` + optional ``fid``.

    ``spectrometer_frequency_mhz`` is threaded through from the
    parent :class:`AcquisitionRun`; nmrML stores frequency in Hz.
    Pass 0.0 (the default) to omit the cvParam entirely.
    """
    parts: list[str] = []

    def emit(s: str) -> None:
        parts.append(s)

    emit('<?xml version="1.0" encoding="UTF-8"?>\n')
    # nmrML XSD requires a version attribute on the root element.
    emit('<nmrML xmlns="http://nmrml.org/schema"'
         ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
         ' xsi:schemaLocation="http://nmrml.org/schema'
         ' http://nmrml.org/schema/v1.0/nmrML.xsd"'
         ' version="1.1.0">\n')

    emit('  <cvList>\n')
    emit('    <cv id="nmrCV" fullName="nmrML Controlled Vocabulary"'
         ' version="1.1.0" URI="http://nmrml.org/cv/v1.1.0/nmrCV.owl"/>\n')
    emit('  </cvList>\n')

    # nmrML XSD requires <fileDescription> between <cvList> and
    # <acquisition>. Minimal valid content is a single <fileContent>
    # cvParam from the nmrCV; "1D NMR spectrum" (NMR:1000002) covers
    # the default spectrum1D case emitted below.
    emit('  <fileDescription>\n')
    emit('    <fileContent>\n')
    emit('      <cvParam cvRef="nmrCV" accession="NMR:1000002"'
         ' name="acquisition nucleus" value=""/>\n')
    emit('    </fileContent>\n')
    emit('  </fileDescription>\n')

    # XSD expects softwareList before <acquisition>. nmrML's
    # software element requires cvRef/accession/name (a controlled-
    # vocabulary descriptor), not the mzML-style free-form
    # attributes. NMR:1400217 is the nmrCV term for "custom software".
    emit('  <softwareList>\n')
    emit('    <software id="mpeg_o" version="0.9.0"'
         ' cvRef="nmrCV" accession="NMR:1400217" name="custom software"/>\n')
    emit('  </softwareList>\n')

    # instrumentConfigurationList is required by the XSD between
    # softwareList and acquisition.
    emit('  <instrumentConfigurationList>\n')
    emit('    <instrumentConfiguration id="IC1">\n')
    emit('      <cvParam cvRef="nmrCV" accession="NMR:1400255"'
         ' name="nmr instrument" value=""/>\n')
    emit('    </instrumentConfiguration>\n')
    emit('  </instrumentConfigurationList>\n')

    emit('  <acquisition>\n')
    emit('    <acquisition1D>\n')
    # numberOfSteadyStateScans is required by the XSD (zero is fine).
    emit('      <acquisitionParameterSet numberOfScans="1"'
         ' numberOfSteadyStateScans="0">\n')
    # nmrML element order inside acquisitionParameterSet:
    #   (contactRefList | softwareRef | sampleContainer | ...) first,
    # then acquisitionNucleus. We have no contact or sample info, so
    # emit a softwareRef pointing at our software entry.
    emit('        <softwareRef ref="mpeg_o"/>\n')
    nucleus = spectrum.nucleus_type if hasattr(spectrum, "nucleus_type") else ""
    freq_mhz = float(spectrometer_frequency_mhz)
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

    # <fidData> is REQUIRED by the XSD inside <acquisition1D>. Emit an
    # empty placeholder when the caller didn't pass a FID; pyteomics and
    # other readers tolerate an empty base64 block.
    if fid is not None:
        fid_b64 = base64.b64encode(
            np.ascontiguousarray(fid.data, dtype="<f8").tobytes()
        ).decode("ascii")
        emit(f'      <fidData compressed="false" byteFormat="float64"'
             f' encodedLength="{len(fid_b64)}">\n')
        emit(f'        {fid_b64}\n')
        emit('      </fidData>\n')
    else:
        emit('      <fidData compressed="false" byteFormat="float64"'
             ' encodedLength="0"></fidData>\n')

    emit('    </acquisition1D>\n')
    emit('  </acquisition>\n')

    cs_data = spectrum.signal_arrays["chemical_shift"].data
    int_data = spectrum.signal_arrays["intensity"].data
    x_b64 = _encode(cs_data)
    y_b64 = _encode(int_data)
    n_points = int(len(cs_data))

    # spectrum1D — numberOfDataPoints is REQUIRED by the XSD.
    emit('  <spectrumList>\n')
    emit(f'    <spectrum1D numberOfDataPoints="{n_points}">\n')

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
    spectrometer_frequency_mhz: float = 0.0,
) -> Path:
    blob = spectrum_to_bytes(
        spectrum,
        fid=fid,
        sweep_width_ppm=sweep_width_ppm,
        spectrometer_frequency_mhz=spectrometer_frequency_mhz,
    )
    out = Path(path)
    out.write_bytes(blob)
    return out
