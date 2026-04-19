"""nmrML import → .mpgo → nmrML export round-trip fidelity (v0.9 M58).

The nmrML pipeline is shallower than mzML at v0.8. The reader extracts
``chemical_shift``, ``intensity``, ``nucleus_type``, sweep width, and
acquisition frequency into ``ImportResult`` state, but
``ImportResult.build_runs`` only carries ``chemical_shift`` + intensity
through into the .mpgo. The writer emits nucleus, optional FID, and
the two arrays.

This file tests fidelity at the level that *is* wired:

* chemical shift array (float64 epsilon)
* intensity array (float64 epsilon)
* nucleus type (string)
* sweep width preservation through the writer
* number of NMR spectra

What the HANDOFF asks for that does **not** round-trip today is
captured under the ``aspirational`` marker:

* complex128 FID real + imaginary survival
* spectrometer frequency restoration on read after write
* number-of-scans propagation

Those tests document the v1.0 bar; see ARCHITECTURE.md "Caller
refactor status" — the bulk-channel writes still drop to native HDF5,
so any extra metadata has to be threaded through ``WrittenRun`` first.
"""
from __future__ import annotations

import base64
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset
from mpeg_o.axis_descriptor import AxisDescriptor
from mpeg_o.exporters import nmrml as nmrml_writer
from mpeg_o.importers import nmrml as nmrml_reader
from mpeg_o.nmr_spectrum import NMRSpectrum
from mpeg_o.signal_array import SignalArray

from _provider_matrix import PROVIDERS as _PROVIDERS, maybe_skip_provider as _maybe_skip_provider


# --------------------------------------------------------------------------- #
# Synthetic-fixture builders.
# --------------------------------------------------------------------------- #

def _b64(arr: np.ndarray) -> str:
    return base64.b64encode(np.ascontiguousarray(arr, dtype="<f8").tobytes()).decode("ascii")


def _build_synthetic_nmrml(
    *,
    n_points: int,
    nucleus: str,
    freq_hz: float,
    sweep_width_ppm: float,
    n_scans: int,
    rng: np.random.Generator,
) -> tuple[str, np.ndarray, np.ndarray]:
    cs = np.linspace(-1.0, 12.0, n_points)
    intensity = rng.uniform(-1.0, 1.0, size=n_points) * 1e4
    cs_b64 = _b64(cs)
    it_b64 = _b64(intensity)
    text = f"""<?xml version="1.0" encoding="UTF-8"?>
<nmrML xmlns="http://nmrml.org/schema">
  <cvList>
    <cv id="nmrCV" fullName="nmrML CV" version="1.1.0"/>
  </cvList>
  <acquisition>
    <acquisition1D>
      <acquisitionParameterSet numberOfScans="{n_scans}">
        <acquisitionNucleus name="{nucleus}"/>
        <irradiationFrequency value="{freq_hz}"/>
        <sweepWidth value="{sweep_width_ppm}"/>
      </acquisitionParameterSet>
    </acquisition1D>
  </acquisition>
  <spectrumList>
    <spectrum1D>
      <xAxis>
        <spectrumDataArray compressed="false" encodedLength="{len(cs_b64)}">
          {cs_b64}
        </spectrumDataArray>
      </xAxis>
      <yAxis>
        <spectrumDataArray compressed="false" encodedLength="{len(it_b64)}">
          {it_b64}
        </spectrumDataArray>
      </yAxis>
    </spectrum1D>
  </spectrumList>
</nmrML>
"""
    return text, cs, intensity


@pytest.fixture()
def synthetic_nmrml(tmp_path: Path) -> tuple[Path, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(1729)
    text, cs, intensity = _build_synthetic_nmrml(
        n_points=512, nucleus="1H",
        freq_hz=600.13e6, sweep_width_ppm=14.0, n_scans=16,
        rng=rng,
    )
    path = tmp_path / "synth.nmrML"
    path.write_text(text)
    return path, cs, intensity


# --------------------------------------------------------------------------- #
# Wired round-trips: nmrML → ImportResult → .mpgo → NMRSpectrum → nmrML.
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("provider", _PROVIDERS)
def test_nmrml_full_roundtrip(provider: str, synthetic_nmrml, tmp_path: Path) -> None:
    """chemical_shift, intensity, nucleus, and spectrum count survive."""
    _maybe_skip_provider(provider)
    src, expected_cs, expected_intensity = synthetic_nmrml

    original = nmrml_reader.read(src)
    assert len(original.nmr_spectra) == 1
    assert original.nucleus_type == "1H"
    np.testing.assert_allclose(
        original.nmr_spectra[0].mz_or_chemical_shift, expected_cs, rtol=1e-9, atol=0,
    )

    mpgo = tmp_path / "rt.nmrml.mpgo"
    original.to_mpgo(mpgo)

    with SpectralDataset.open(mpgo) as ds:
        run = ds.ms_runs["nmr_run"]  # write_minimal places NMR runs in ms_runs (see test_importers)
        assert run.spectrum_class == "MPGONMRSpectrum"
        assert len(run) == 1
        spec = run[0]

    cs_data = spec.signal_arrays["chemical_shift"].data
    intensity_data = spec.signal_arrays["intensity"].data
    np.testing.assert_allclose(cs_data, expected_cs, rtol=1e-9, atol=0)
    np.testing.assert_allclose(intensity_data, expected_intensity, rtol=1e-9, atol=0)

    # Round-trip back to nmrML and re-import.
    nmr_spec = NMRSpectrum(
        signal_arrays={
            "chemical_shift": SignalArray.from_numpy(
                cs_data, axis=AxisDescriptor(name="chemical_shift", unit="ppm"),
            ),
            "intensity": SignalArray.from_numpy(
                intensity_data, axis=AxisDescriptor(name="intensity", unit="counts"),
            ),
        },
        nucleus_type=run.nucleus_type or "1H",
        scan_time_seconds=0.0,
        precursor_mz=0.0,
        precursor_charge=0,
        index_position=0,
    )
    out = tmp_path / "rt_out.nmrML"
    nmrml_writer.write_spectrum(nmr_spec, out, sweep_width_ppm=14.0)

    re_imported = nmrml_reader.read(out)
    assert len(re_imported.nmr_spectra) == 1
    assert re_imported.nucleus_type == "1H"
    np.testing.assert_allclose(
        re_imported.nmr_spectra[0].mz_or_chemical_shift, expected_cs, rtol=1e-9, atol=0,
    )
    np.testing.assert_allclose(
        re_imported.nmr_spectra[0].intensity, expected_intensity, rtol=1e-9, atol=0,
    )


def test_nmrml_writer_emits_sweep_width(tmp_path: Path) -> None:
    """The writer surfaces sweep_width_ppm in the acquisitionParameterSet."""
    spec = NMRSpectrum(
        signal_arrays={
            "chemical_shift": SignalArray.from_numpy(
                np.linspace(0.0, 10.0, 4), axis=AxisDescriptor(name="chemical_shift", unit="ppm"),
            ),
            "intensity": SignalArray.from_numpy(
                np.array([1.0, 2.0, 3.0, 4.0]), axis=AxisDescriptor(name="intensity", unit="counts"),
            ),
        },
        nucleus_type="1H",
        scan_time_seconds=0.0,
        precursor_mz=0.0,
        precursor_charge=0,
        index_position=0,
    )
    out = tmp_path / "sw.nmrML"
    nmrml_writer.write_spectrum(spec, out, sweep_width_ppm=12.5)
    text = out.read_text()
    assert 'name="sweep width" value="12.5"' in text

    re_read = nmrml_reader.read(out)
    assert re_read.nucleus_type == "1H"


# --------------------------------------------------------------------------- #
# Aspirational fidelity targets — document the v1.0 bar.
#
# These tests exercise the real pipeline and use ``xfail(strict=True)`` so:
#   * default CI ignores them (filtered by ``not aspirational``)
#   * nightly CI runs them and reports XFAIL (passing)
#   * once the feature lands they XPASS — strict mode flips the run red
#     and reminds someone to drop the marker
# --------------------------------------------------------------------------- #

@pytest.mark.aspirational
@pytest.mark.xfail(strict=True, reason="ImportResult.build_runs drops FID arrays — v0.9+ work")
def test_complex128_fid_round_trip(tmp_path: Path) -> None:
    """Complex FID (real + imag) survives the full pipeline."""
    n = 64
    real = np.linspace(-1.0, 1.0, n)
    imag = np.linspace(0.5, -0.5, n)
    fid_b64 = base64.b64encode(
        np.ascontiguousarray(np.stack([real, imag], axis=1).reshape(-1), dtype="<f8").tobytes()
    ).decode("ascii")
    text = f"""<?xml version="1.0" encoding="UTF-8"?>
<nmrML xmlns="http://nmrml.org/schema">
  <cvList><cv id="nmrCV" fullName="x" version="1.1.0"/></cvList>
  <acquisition><acquisition1D>
    <acquisitionParameterSet numberOfScans="1">
      <acquisitionNucleus name="1H"/>
    </acquisitionParameterSet>
    <fidData compressed="false" byteFormat="complex128" encodedLength="{len(fid_b64)}">
      {fid_b64}
    </fidData>
  </acquisition1D></acquisition>
</nmrML>
"""
    src = tmp_path / "fid.nmrML"
    src.write_text(text)
    result = nmrml_reader.read(src)
    # The aspirational bar: FID arrays make it into the ImportResult.
    assert hasattr(result, "fid_real")
    np.testing.assert_allclose(result.fid_real, real, rtol=1e-9)
    np.testing.assert_allclose(result.fid_imag, imag, rtol=1e-9)


@pytest.mark.aspirational
@pytest.mark.xfail(strict=True, reason="NMRSpectrum has no frequency field — v0.9+ work")
def test_spectrometer_frequency_round_trip(tmp_path: Path, synthetic_nmrml) -> None:
    """Spectrometer frequency parsed on read survives a re-export."""
    src, _, _ = synthetic_nmrml
    parsed = nmrml_reader.read(src)
    assert getattr(parsed, "spectrometer_frequency_mhz", 0.0) > 0.0


@pytest.mark.aspirational
@pytest.mark.xfail(strict=True, reason="numberOfScans not propagated through WrittenRun — v0.9+")
def test_number_of_scans_round_trip(tmp_path: Path, synthetic_nmrml) -> None:
    """numberOfScans survives import → mpgo → re-export → re-import."""
    src, _, _ = synthetic_nmrml
    parsed = nmrml_reader.read(src)
    assert getattr(parsed, "number_of_scans", 0) == 16
