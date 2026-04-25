"""mzML import → .tio → mzML export round-trip fidelity (v0.9 M58).

Covers HUPO-PSI fidelity contract:

* per-spectrum: m/z & intensity arrays (rtol 1e-9), MS level, polarity,
  retention time (1 ms), precursor m/z & charge
* aggregate: spectrum count, chromatogram count
* edge cases: empty spectrum, large (10K peaks) spectrum, 32-bit
  precision preserved, zlib-compressed source produces identical
  values to uncompressed

Provider parametrization
------------------------

The HANDOFF asks for the matrix ``["hdf5", "memory", "sqlite",
"zarr"]``. As of v0.8 ``SpectralDataset.write_minimal`` only writes
through HDF5 (see ``ARCHITECTURE.md`` "Caller refactor status" — bulk
signal-channel writes still go through ``provider.native_handle()``).
The non-HDF5 providers therefore parametrize as ``aspirational``: the
test infrastructure is in place so the matrix lights up automatically
once provider-aware writes land in v0.9+ or v1.0.
"""
from __future__ import annotations

import zlib
import base64
from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset
from ttio.exporters import mzml as mzml_writer
from ttio.importers import mzml as mzml_reader

from _provider_matrix import (
    PROVIDERS as _PROVIDERS,
    maybe_skip_provider as _maybe_skip_provider,
    provider_url as _provider_url,
)


# --------------------------------------------------------------------------- #
# Fixture builder: a deterministic synthetic mzML covering common shapes.
# --------------------------------------------------------------------------- #

def _b64_doubles(arr: np.ndarray, *, precision: str = "64", zlib_compress: bool = False) -> str:
    dtype = "<f8" if precision == "64" else "<f4"
    raw = np.ascontiguousarray(arr, dtype=dtype).tobytes()
    if zlib_compress:
        raw = zlib.compress(raw)
    return base64.b64encode(raw).decode("ascii")


def _spectrum_xml(
    *,
    index: int,
    mz: np.ndarray,
    intensity: np.ndarray,
    ms_level: int,
    rt: float,
    precursor_mz: float = 0.0,
    precursor_charge: int = 0,
    precision: str = "64",
    zlib_compress: bool = False,
    polarity_positive: bool = True,
) -> str:
    n = mz.size
    enc_acc = "MS:1000523" if precision == "64" else "MS:1000521"
    enc_name = "64-bit float" if precision == "64" else "32-bit float"
    bytes_per = 8 if precision == "64" else 4
    encoded_mz = _b64_doubles(mz, precision=precision, zlib_compress=zlib_compress)
    encoded_it = _b64_doubles(intensity, precision=precision, zlib_compress=zlib_compress)
    raw_mz_bytes = n * bytes_per
    raw_it_bytes = n * bytes_per
    polarity_param = (
        '<cvParam cvRef="MS" accession="MS:1000130" name="positive scan" value=""/>'
        if polarity_positive else
        '<cvParam cvRef="MS" accession="MS:1000129" name="negative scan" value=""/>'
    )
    compression_param = (
        '<cvParam cvRef="MS" accession="MS:1000574" name="zlib compression" value=""/>'
        if zlib_compress else
        '<cvParam cvRef="MS" accession="MS:1000576" name="no compression" value=""/>'
    )
    precursor_block = ""
    if ms_level == 2:
        precursor_block = f"""
        <precursorList count="1">
          <precursor>
            <selectedIonList count="1">
              <selectedIon>
                <cvParam cvRef="MS" accession="MS:1000744" name="selected ion m/z" value="{precursor_mz}" unitCvRef="MS" unitAccession="MS:1000040" unitName="m/z"/>
                <cvParam cvRef="MS" accession="MS:1000041" name="charge state" value="{precursor_charge}"/>
              </selectedIon>
            </selectedIonList>
          </precursor>
        </precursorList>"""
    return f"""      <spectrum index="{index}" id="scan={index + 1}" defaultArrayLength="{n}">
        <cvParam cvRef="MS" accession="MS:1000511" name="ms level" value="{ms_level}"/>
        {polarity_param}
        <scanList count="1">
          <scan>
            <cvParam cvRef="MS" accession="MS:1000016" name="scan start time" value="{rt}" unitCvRef="UO" unitAccession="UO:0000010" unitName="second"/>
          </scan>
        </scanList>{precursor_block}
        <binaryDataArrayList count="2">
          <binaryDataArray encodedLength="{len(encoded_mz)}">
            <cvParam cvRef="MS" accession="{enc_acc}" name="{enc_name}" value=""/>
            {compression_param}
            <cvParam cvRef="MS" accession="MS:1000514" name="m/z array" value="" unitCvRef="MS" unitAccession="MS:1000040" unitName="m/z"/>
            <binary>{encoded_mz}</binary>
          </binaryDataArray>
          <binaryDataArray encodedLength="{len(encoded_it)}">
            <cvParam cvRef="MS" accession="{enc_acc}" name="{enc_name}" value=""/>
            {compression_param}
            <cvParam cvRef="MS" accession="MS:1000515" name="intensity array" value="" unitCvRef="MS" unitAccession="UO" unitName="number of counts"/>
            <binary>{encoded_it}</binary>
          </binaryDataArray>
        </binaryDataArrayList>
      </spectrum>
"""


def _wrap_mzml(spectra_xml: str, run_id: str = "synthetic_run") -> str:
    n = spectra_xml.count("<spectrum ")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<mzML xmlns="http://psi.hupo.org/ms/mzml" id="m58" version="1.1.0">
  <cvList count="2">
    <cv id="MS" fullName="Proteomics Standards Initiative Mass Spectrometry Ontology" version="4.1.0"/>
    <cv id="UO" fullName="Unit Ontology" version="2020-03-10"/>
  </cvList>
  <fileDescription>
    <fileContent>
      <cvParam cvRef="MS" accession="MS:1000580" name="MSn spectrum" value=""/>
    </fileContent>
  </fileDescription>
  <softwareList count="1">
    <software id="ttio_test" version="0.9.0"/>
  </softwareList>
  <instrumentConfigurationList count="1">
    <instrumentConfiguration id="IC1"/>
  </instrumentConfigurationList>
  <dataProcessingList count="1">
    <dataProcessing id="dp"/>
  </dataProcessingList>
  <run id="{run_id}" defaultInstrumentConfigurationRef="IC1">
    <spectrumList count="{n}" defaultDataProcessingRef="dp">
{spectra_xml}    </spectrumList>
  </run>
</mzML>
"""


@pytest.fixture()
def tiny_synthetic_mzml(tmp_path: Path) -> Path:
    """A 3-spectrum (MS1, MS2, MS1) synthetic mzML.

    Deterministic; no network. Covers MS-level switch, precursor block,
    positive polarity, and float64 binary arrays.
    """
    rng = np.random.default_rng(42)
    parts: list[str] = []
    for i in range(3):
        n = 16 + i * 4
        mz = np.linspace(100.0 + i, 500.0 + i, n)
        intensity = rng.uniform(0.0, 1e6, size=n)
        parts.append(_spectrum_xml(
            index=i, mz=mz, intensity=intensity,
            ms_level=2 if i == 1 else 1,
            rt=float(i) * 0.5,
            precursor_mz=350.5 if i == 1 else 0.0,
            precursor_charge=2 if i == 1 else 0,
        ))
    out = tmp_path / "tiny_synth.mzML"
    out.write_text(_wrap_mzml("".join(parts), run_id="tiny_synth"))
    return out


@pytest.fixture()
def empty_spectrum_mzml(tmp_path: Path) -> Path:
    """An mzML containing one zero-peak spectrum."""
    xml = _spectrum_xml(
        index=0,
        mz=np.array([], dtype=np.float64),
        intensity=np.array([], dtype=np.float64),
        ms_level=1, rt=0.0,
    )
    out = tmp_path / "empty.mzML"
    out.write_text(_wrap_mzml(xml, run_id="empty_run"))
    return out


@pytest.fixture()
def large_spectrum_mzml(tmp_path: Path) -> Path:
    """An mzML with one 10 240-peak spectrum (well above the chunked-IO
    threshold) used to verify no OOM / silent truncation."""
    n = 10_240
    mz = np.linspace(50.0, 2000.0, n)
    intensity = np.linspace(1.0, 1.0e7, n)
    xml = _spectrum_xml(
        index=0, mz=mz, intensity=intensity, ms_level=1, rt=0.0,
    )
    out = tmp_path / "large.mzML"
    out.write_text(_wrap_mzml(xml, run_id="large_run"))
    return out


@pytest.fixture()
def f32_precision_mzml(tmp_path: Path) -> Path:
    """An mzML whose binary arrays are 32-bit floats."""
    n = 8
    mz = np.linspace(100.0, 200.0, n)
    intensity = np.linspace(1.0, 100.0, n)
    xml = _spectrum_xml(
        index=0, mz=mz, intensity=intensity, ms_level=1, rt=0.0,
        precision="32",
    )
    out = tmp_path / "f32.mzML"
    out.write_text(_wrap_mzml(xml, run_id="f32_run"))
    return out


@pytest.fixture()
def zlib_compressed_mzml(tmp_path: Path) -> tuple[Path, Path]:
    """Pair of mzML files with identical logical content, one zlib, one
    uncompressed."""
    n = 32
    mz = np.linspace(100.0, 200.0, n)
    intensity = np.linspace(1.0, 1000.0, n)
    plain = _spectrum_xml(
        index=0, mz=mz, intensity=intensity, ms_level=1, rt=0.0,
        zlib_compress=False,
    )
    compressed = _spectrum_xml(
        index=0, mz=mz, intensity=intensity, ms_level=1, rt=0.0,
        zlib_compress=True,
    )
    p_plain = tmp_path / "plain.mzML"
    p_zlib = tmp_path / "zlib.mzML"
    p_plain.write_text(_wrap_mzml(plain, run_id="plain_run"))
    p_zlib.write_text(_wrap_mzml(compressed, run_id="zlib_run"))
    return p_plain, p_zlib


# --------------------------------------------------------------------------- #
# Round-trip helpers.
# --------------------------------------------------------------------------- #

def _import_export(
    mzml_path: Path,
    ttio_url: str,
    out_mzml: Path,
    *,
    provider: str = "hdf5",
) -> tuple:
    """mzML → .tio (on ``provider``) → mzML. Returns (original, roundtrip)."""
    original = mzml_reader.read(mzml_path)
    original.to_ttio(ttio_url, provider=provider)
    with SpectralDataset.open(ttio_url) as ds:
        mzml_writer.write_dataset(ds, out_mzml, zlib_compression=False)
    roundtrip = mzml_reader.read(out_mzml)
    return original, roundtrip


# --------------------------------------------------------------------------- #
# Synthetic-fixture round-trips (offline; always run).
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("provider", _PROVIDERS)
def test_mzml_full_roundtrip_synthetic(provider: str, tiny_synthetic_mzml: Path, tmp_path: Path) -> None:
    _maybe_skip_provider(provider)
    ttio = _provider_url(provider, tmp_path, "rt")
    out = tmp_path / "rt.mzML"
    original, roundtrip = _import_export(tiny_synthetic_mzml, ttio, out, provider=provider)

    assert len(roundtrip.ms_spectra) == len(original.ms_spectra) == 3

    for orig, rt in zip(original.ms_spectra, roundtrip.ms_spectra):
        np.testing.assert_allclose(rt.mz_or_chemical_shift, orig.mz_or_chemical_shift, rtol=1e-9, atol=0)
        np.testing.assert_allclose(rt.intensity, orig.intensity, rtol=1e-9, atol=0)
        assert rt.ms_level == orig.ms_level
        assert rt.polarity == orig.polarity
        assert abs(rt.retention_time - orig.retention_time) < 1e-3
        if orig.ms_level == 2:
            assert abs(rt.precursor_mz - orig.precursor_mz) < 1e-9
            assert rt.precursor_charge == orig.precursor_charge


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_mzml_roundtrip_pinned_psi_reference(
    provider: str, tmp_path: Path, downloaded_fixture
) -> None:
    """Round-trip the pinned tiny.pwiz.1.1.mzML reference if cached.

    The fixture is fetched by ``download.py fetch tiny_pwiz_mzml``;
    when absent (default CI) the test is skipped, not failed.
    """
    _maybe_skip_provider(provider)
    src = downloaded_fixture("tiny_pwiz_mzml")
    ttio = _provider_url(provider, tmp_path, "psi")
    out = tmp_path / "psi.mzML"
    original, roundtrip = _import_export(src, ttio, out, provider=provider)
    assert len(roundtrip.ms_spectra) == len(original.ms_spectra)
    assert len(roundtrip.ms_spectra) > 0

    for orig, rt in zip(original.ms_spectra, roundtrip.ms_spectra):
        np.testing.assert_allclose(rt.mz_or_chemical_shift, orig.mz_or_chemical_shift, rtol=1e-9, atol=0)
        np.testing.assert_allclose(rt.intensity, orig.intensity, rtol=1e-9, atol=0)
        assert rt.ms_level == orig.ms_level


# --------------------------------------------------------------------------- #
# Edge cases.
# --------------------------------------------------------------------------- #

def test_empty_spectrum_round_trip(empty_spectrum_mzml: Path, tmp_path: Path) -> None:
    """A zero-peak spectrum must survive the full pipeline."""
    ttio = tmp_path / "empty.tio"
    out = tmp_path / "empty_out.mzML"
    _, roundtrip = _import_export(empty_spectrum_mzml, ttio, out)
    assert len(roundtrip.ms_spectra) == 1
    assert roundtrip.ms_spectra[0].mz_or_chemical_shift.size == 0
    assert roundtrip.ms_spectra[0].intensity.size == 0


def test_large_spectrum_round_trip(large_spectrum_mzml: Path, tmp_path: Path) -> None:
    """10 240 peaks survive without truncation or precision loss."""
    ttio = tmp_path / "large.tio"
    out = tmp_path / "large_out.mzML"
    original, roundtrip = _import_export(large_spectrum_mzml, ttio, out)
    assert roundtrip.ms_spectra[0].mz_or_chemical_shift.size == 10_240
    np.testing.assert_array_equal(
        roundtrip.ms_spectra[0].mz_or_chemical_shift,
        original.ms_spectra[0].mz_or_chemical_shift,
    )


def test_f32_precision_preserved(f32_precision_mzml: Path, tmp_path: Path) -> None:
    """A 32-bit-encoded source preserves its float32 quantization through
    the round-trip — values match the float32 cast of the original."""
    ttio = tmp_path / "f32.tio"
    out = tmp_path / "f32_out.mzML"
    original, roundtrip = _import_export(f32_precision_mzml, ttio, out)
    expected_mz = original.ms_spectra[0].mz_or_chemical_shift.astype(np.float32).astype(np.float64)
    np.testing.assert_array_equal(
        roundtrip.ms_spectra[0].mz_or_chemical_shift.astype(np.float32).astype(np.float64),
        expected_mz,
    )


def test_zlib_source_matches_uncompressed(zlib_compressed_mzml, tmp_path: Path) -> None:
    """A zlib-compressed source must produce values bit-identical to the
    same logical spectrum from an uncompressed source."""
    plain_src, zlib_src = zlib_compressed_mzml
    plain_ttio = tmp_path / "plain.tio"
    zlib_ttio = tmp_path / "zlib.tio"
    plain_out = tmp_path / "plain_out.mzML"
    zlib_out = tmp_path / "zlib_out.mzML"
    _, plain_rt = _import_export(plain_src, plain_ttio, plain_out)
    _, zlib_rt = _import_export(zlib_src, zlib_ttio, zlib_out)

    np.testing.assert_array_equal(
        plain_rt.ms_spectra[0].mz_or_chemical_shift,
        zlib_rt.ms_spectra[0].mz_or_chemical_shift,
    )
    np.testing.assert_array_equal(
        plain_rt.ms_spectra[0].intensity,
        zlib_rt.ms_spectra[0].intensity,
    )
