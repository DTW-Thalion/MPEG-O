"""Milestone 29 — nmrML writer + Thermo RAW stub."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.exporters.nmrml import spectrum_to_bytes, write_spectrum
from ttio.nmr_spectrum import NMRSpectrum
from ttio.signal_array import SignalArray
from ttio.axis_descriptor import AxisDescriptor


def _make_spectrum() -> NMRSpectrum:
    cs = np.array([0.5, 1.5, 2.5, 3.5], dtype=np.float64)
    it = np.array([10.0, 20.0, 30.0, 20.0], dtype=np.float64)
    return NMRSpectrum(
        signal_arrays={
            "chemical_shift": SignalArray.from_numpy(cs, axis=AxisDescriptor(name="chemical_shift", unit="ppm")),
            "intensity": SignalArray.from_numpy(it, axis=AxisDescriptor(name="intensity", unit="counts")),
        },
        nucleus_type="1H",
        scan_time_seconds=0.0,
        precursor_mz=0.0,
        precursor_charge=0,
        index_position=0,
    )


def test_nmrml_writer_produces_valid_xml() -> None:
    spec = _make_spectrum()
    blob = spectrum_to_bytes(spec, sweep_width_ppm=10.0)
    text = blob.decode("utf-8")
    assert "<nmrML" in text
    # v0.9 M64 canonical form: spectrometer frequency is emitted
    # via <irradiationFrequency>, sweep width via <sweepWidth>, in
    # DirectDimensionParameterSet. The cvParam forms were dropped
    # because the XSD doesn't allow cvParams at the AcquisitionParameterSet
    # level. NMR:1000002 (acquisition nucleus) stays as CVTermType attrs.
    assert "NMR:1000002" in text
    assert "<irradiationFrequency" in text
    assert "<sweepWidth" in text
    # v0.9 M64: <spectrum1D> now carries the required numberOfDataPoints
    # attribute per nmrML XSD; match with a looser prefix check. The
    # writer now emits canonical single-<spectrumDataArray> (interleaved
    # x,y pairs) + attribute-only <xAxis> instead of the legacy
    # <xAxis><spectrumDataArray/></xAxis> + <yAxis> wrappers.
    assert "<spectrum1D" in text
    assert "<spectrumDataArray" in text
    assert "<xAxis" in text


def test_nmrml_write_to_disk(tmp_path: Path) -> None:
    spec = _make_spectrum()
    out = tmp_path / "test.nmrML"
    write_spectrum(spec, out, sweep_width_ppm=10.0)
    assert out.is_file()
    assert out.stat().st_size > 100


def test_nmrml_writer_emits_xsd_required_wrapper_sections() -> None:
    """v0.9 M64: nmrML writer output must include every section the XSD
    content model requires before <acquisition>: cvList, fileDescription,
    softwareList, instrumentConfigurationList. Previously the writer
    skipped fileDescription + the two lists, which broke XSD validation."""
    spec = _make_spectrum()
    blob = spectrum_to_bytes(spec, sweep_width_ppm=10.0)
    text = blob.decode("utf-8")
    assert 'version="1.1.0"' in text, "<nmrML> root must carry version attr"
    assert "<fileDescription>" in text
    assert "<softwareList>" in text
    assert "<instrumentConfigurationList>" in text
    # The XSD requires these elements to appear in sequence:
    #   cvList → fileDescription → softwareList → instrumentConfigurationList → acquisition
    cv_pos = text.index("<cvList>")
    fd_pos = text.index("<fileDescription>")
    sw_pos = text.index("<softwareList>")
    ic_pos = text.index("<instrumentConfigurationList>")
    ac_pos = text.index("<acquisition>")
    assert cv_pos < fd_pos < sw_pos < ic_pos < ac_pos, (
        "XSD-required element order: cvList, fileDescription, softwareList,"
        " instrumentConfigurationList, acquisition"
    )


def test_nmrml_writer_emits_direct_dimension_parameter_set() -> None:
    """v0.9 M64: spectrometer frequency and sweep width moved from
    cvParams at the acquisitionParameterSet level (XSD-invalid) into the
    DirectDimensionParameterSet block as typed elements."""
    spec = _make_spectrum()
    blob = spectrum_to_bytes(spec, sweep_width_ppm=12.5,
                              spectrometer_frequency_mhz=600.0)
    text = blob.decode("utf-8")
    assert "<DirectDimensionParameterSet" in text
    assert 'decoupled="false"' in text, "decoupled attr required by XSD"
    assert 'numberOfDataPoints=' in text, "numberOfDataPoints attr required"
    # The sweep width is the value we passed; frequency is Hz = MHz × 1e6.
    assert '<sweepWidth value="12.5"' in text
    assert '<irradiationFrequency value="600000000"' in text
    # All the XSD-required children must be present.
    for child in ("<acquisitionNucleus", "<effectiveExcitationField",
                  "<pulseWidth", "<irradiationFrequencyOffset",
                  "<samplingStrategy"):
        assert child in text, f"DirectDimensionParameterSet missing {child}"


def test_nmrml_spectrum1d_emits_interleaved_xy_array() -> None:
    """v0.9 M64: <spectrum1D> now has a single <spectrumDataArray>
    carrying interleaved (x, y) doubles + attribute-only <xAxis>, per the
    nmrML XSD content model. encodedLength == numberOfDataPoints × 16
    (2 doubles × 8 bytes) when base64 round-trip is applied."""
    spec = _make_spectrum()
    blob = spectrum_to_bytes(spec, sweep_width_ppm=10.0)
    text = blob.decode("utf-8")
    # numberOfDataPoints on spectrum1D matches the intensity array length.
    import re
    match = re.search(r'<spectrum1D id="s1" numberOfDataPoints="(\d+)"', text)
    assert match is not None, "<spectrum1D> must carry id + numberOfDataPoints"
    n = int(match.group(1))
    assert n == 4  # _make_spectrum() builds a 4-point spectrum.
    # The xAxis is attribute-only (no child elements); spectrumDataArray
    # is a single sibling carrying the interleaved blob.
    assert "<xAxis unitAccession=" in text
    assert "<spectrumDataArray" in text
    assert 'byteFormat="Complex128"' in text, (
        "XSD requires byteFormat attribute on BinaryDataArrayType"
    )


def test_nmrml_fid_data_emits_byte_format_attribute() -> None:
    """v0.9 M64: fidData must carry the required byteFormat attribute."""
    spec = _make_spectrum()
    blob = spectrum_to_bytes(spec, sweep_width_ppm=10.0)
    text = blob.decode("utf-8")
    assert '<fidData compressed="false" byteFormat=' in text


def test_thermo_raw_rejects_missing_file() -> None:
    # M29 stub raised NotImplementedError unconditionally; M38 replaced
    # the stub with a real ThermoRawFileParser delegation, which rejects
    # a missing input path before looking for the binary.
    from ttio.importers.thermo_raw import read
    with pytest.raises(FileNotFoundError):
        read("/tmp/definitely-does-not-exist-ttio-m38.raw")
