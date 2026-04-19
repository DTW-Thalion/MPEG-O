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

    nucleus = spectrum.nucleus_type if hasattr(spectrum, "nucleus_type") else ""
    freq_mhz = float(spectrometer_frequency_mhz)
    freq_hz = freq_mhz * 1.0e6

    emit('  <acquisition>\n')
    emit('    <acquisition1D>\n')
    # numberOfSteadyStateScans is required by the XSD (zero is fine).
    emit('      <acquisitionParameterSet numberOfScans="1"'
         ' numberOfSteadyStateScans="0">\n')
    # Per AcquisitionParameterSetType: softwareRef (optional) must
    # precede sampleContainer (required, CVTermType), followed by
    # sampleAcquisitionTemperature (required, ValueWithUnitType).
    # Strict XSD element order per AcquisitionParameterSet[1D]Type:
    #   softwareRef, sampleContainer, sampleAcquisitionTemperature,
    #   (solventSuppressionMethod), spinningRate, relaxationDelay,
    #   pulseSequence, (shapedPulseFile), (groupDelay),
    #   (acquisitionParameterRefList), DirectDimensionParameterSet
    emit('        <softwareRef ref="mpeg_o"/>\n')
    # sampleContainer: CVTermType — NMR:1400128 = "tube".
    emit('        <sampleContainer cvRef="nmrCV" accession="NMR:1400128"'
         ' name="tube"/>\n')
    # sampleAcquisitionTemperature default: 298 K ≈ room temperature.
    emit('        <sampleAcquisitionTemperature value="298.0"'
         ' unitAccession="UO:0000012" unitName="kelvin" unitCvRef="UO"/>\n')
    # spinningRate + relaxationDelay: zero placeholders when unknown.
    emit('        <spinningRate value="0.0"'
         ' unitAccession="UO:0000106" unitName="hertz" unitCvRef="UO"/>\n')
    emit('        <relaxationDelay value="1.0"'
         ' unitAccession="UO:0000010" unitName="second" unitCvRef="UO"/>\n')
    # pulseSequence: required element; ParamGroupType allows empty body.
    emit('        <pulseSequence/>\n')

    sweep_value = sweep_width_ppm if sweep_width_ppm > 0.0 else 10.0
    n_points_hint = int(len(spectrum.signal_arrays["intensity"].data))
    # DirectDimensionParameterSet requires decoupled (boolean) +
    # numberOfDataPoints (integer) attributes; the element sequence
    # (decouplingMethod?, acquisitionNucleus, effectiveExcitationField,
    # sweepWidth, pulseWidth, irradiationFrequency,
    # irradiationFrequencyOffset, (decouplingNucleus?), samplingStrategy,
    # samplingTimePoints?) is also strict.
    emit(f'        <DirectDimensionParameterSet decoupled="false"'
         f' numberOfDataPoints="{n_points_hint}">\n')
    # acquisitionNucleus is CVTermType (cvRef + accession + name — no value).
    emit(f'          <acquisitionNucleus cvRef="nmrCV" accession="NMR:1000002"'
         f' name="{nucleus or "1H"}"/>\n')
    emit('          <effectiveExcitationField value="0.0"'
         ' unitAccession="UO:0000228" unitName="tesla" unitCvRef="UO"/>\n')
    emit(f'          <sweepWidth value="{_fmt(sweep_value)}"'
         f' unitAccession="UO:0000169" unitName="parts per million"'
         f' unitCvRef="UO"/>\n')
    emit('          <pulseWidth value="10.0"'
         ' unitAccession="UO:0000029" unitName="microsecond" unitCvRef="UO"/>\n')
    emit(f'          <irradiationFrequency value="{_fmt(freq_hz)}"'
         f' unitAccession="UO:0000106" unitName="hertz" unitCvRef="UO"/>\n')
    emit('          <irradiationFrequencyOffset value="0.0"'
         ' unitAccession="UO:0000106" unitName="hertz" unitCvRef="UO"/>\n')
    # samplingStrategy is required; "uniform sampling" is the normal
    # assumption for our synthetic + exported data.
    emit('          <samplingStrategy cvRef="nmrCV" accession="NMR:1400285"'
         ' name="uniform sampling"/>\n')
    emit('        </DirectDimensionParameterSet>\n')

    emit('      </acquisitionParameterSet>\n')

    # <fidData> is REQUIRED by the XSD inside <acquisition1D>. Emit an
    # empty placeholder when the caller didn't pass a FID.
    if fid is not None:
        fid_b64 = base64.b64encode(
            np.ascontiguousarray(fid.data, dtype="<f8").tobytes()
        ).decode("ascii")
        emit(f'      <fidData compressed="false" byteFormat="Complex128"'
             f' encodedLength="{len(fid_b64)}">{fid_b64}</fidData>\n')
    else:
        emit('      <fidData compressed="false" byteFormat="Complex128"'
             ' encodedLength="0"></fidData>\n')

    emit('    </acquisition1D>\n')
    emit('  </acquisition>\n')

    # Spectrum1D content model (per XSD):
    #   <spectrumDataArray> (1, required, type BinaryDataArrayType)
    #   <xAxis> (1, required, AxisWithUnitType — attribute-only)
    #   attribute numberOfDataPoints (required integer)
    #
    # The spec allows the binary payload to be "y-axis values at equal
    # x-axis intervals OR a set of (x,y) pairs" — we use interleaved
    # (x,y) doubles so both arrays round-trip losslessly. Readers can
    # detect the encoding by comparing encodedLength to
    # numberOfDataPoints × 8 (y-only) vs × 16 (interleaved).
    cs_data = spectrum.signal_arrays["chemical_shift"].data
    int_data = spectrum.signal_arrays["intensity"].data
    n_points = int(len(cs_data))
    interleaved = np.empty(n_points * 2, dtype="<f8")
    interleaved[0::2] = cs_data
    interleaved[1::2] = int_data
    xy_b64 = base64.b64encode(interleaved.tobytes()).decode("ascii")

    emit('  <spectrumList>\n')
    emit(f'    <spectrum1D id="s1" numberOfDataPoints="{n_points}">\n')
    emit(f'      <spectrumDataArray compressed="false"'
         f' byteFormat="Complex128" encodedLength="{len(xy_b64)}">'
         f'{xy_b64}</spectrumDataArray>\n')
    emit('      <xAxis unitAccession="UO:0000169"'
         ' unitName="parts per million" unitCvRef="UO"/>\n')
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
