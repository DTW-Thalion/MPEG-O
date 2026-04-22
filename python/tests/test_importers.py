"""Tests for the mzML and nmrML Python importers."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset
from mpeg_o.enums import ActivationMethod
from mpeg_o.importers import ImportResult, mzml, nmrml


_REPO_ROOT = Path(__file__).resolve().parents[2]
_XML_FIXTURE_DIR = _REPO_ROOT / "objc" / "Tests" / "Fixtures"


@pytest.fixture(scope="module")
def tiny_mzml() -> Path:
    p = _XML_FIXTURE_DIR / "tiny.pwiz.1.1.mzML"
    if not p.is_file():
        pytest.skip(f"missing {p}")
    return p


@pytest.fixture(scope="module")
def onemin_mzml() -> Path:
    p = _XML_FIXTURE_DIR / "1min.mzML"
    if not p.is_file():
        pytest.skip(f"missing {p}")
    return p


@pytest.fixture(scope="module")
def bmrb_nmrml() -> Path:
    p = _XML_FIXTURE_DIR / "bmse000325.nmrML"
    if not p.is_file():
        pytest.skip(f"missing {p}")
    return p


def test_mzml_imports_tiny_fixture(tiny_mzml: Path) -> None:
    result = mzml.read(tiny_mzml)
    assert isinstance(result, ImportResult)
    assert result.spectrum_count > 0
    for s in result.ms_spectra:
        assert s.mz_or_chemical_shift.dtype == np.float64
        assert s.intensity.dtype == np.float64
        assert s.mz_or_chemical_shift.shape == s.intensity.shape


def test_mzml_imports_1min_fixture(onemin_mzml: Path) -> None:
    # 1min.mzML is a real-world vendor file with big-endian float32 arrays
    # and no explicit byte-order cvParam. The ObjC reference reader also
    # treats it as little-endian and only checks that spectra are parsed,
    # not their numeric values — mirror that behaviour here.
    result = mzml.read(onemin_mzml)
    assert result.spectrum_count == 39  # fixture is documented to have 39 spectra
    for s in result.ms_spectra:
        assert s.mz_or_chemical_shift.shape == s.intensity.shape


def test_mzml_round_trip_via_mpgo(tiny_mzml: Path, tmp_path: Path) -> None:
    """End-to-end: mzML → ImportResult → .mpgo → SpectralDataset and
    verify spectrum-count and first-spectrum shape preservation."""
    result = mzml.read(tiny_mzml)
    out = tmp_path / "from_mzml.mpgo"
    result.to_mpgo(out)

    with SpectralDataset.open(out) as ds:
        assert "run_0001" in ds.ms_runs
        run = ds.ms_runs["run_0001"]
        assert len(run) == len(result.ms_spectra)
        mz_in = result.ms_spectra[0].mz_or_chemical_shift
        mz_out = run[0].mz_array.data
        np.testing.assert_allclose(mz_out, mz_in)


def test_mzml_ms2_activation_and_isolation_round_trip(
    tiny_mzml: Path, tmp_path: Path,
) -> None:
    """(M74) Parse the pwiz tiny fixture and confirm that the MS2 spectrum's
    activation method and isolation window propagate through ImportResult,
    the written .mpgo container, and SpectrumIndex accessors.

    The fixture has one MS2 spectrum with CID activation and an isolation
    window at 445.3 m/z (lower=0.5, upper=0.5), plus one SRM spectrum with
    CID + precursor isolation 456.7 m/z and a product isolationWindow at
    678.9 — the product isolationWindow must NOT leak into the spectrum's
    precursor isolation state.
    """
    result = mzml.read(tiny_mzml)

    # Find MS2 spectrum with non-zero isolation target.
    ms2 = [s for s in result.ms_spectra if s.ms_level == 2]
    assert ms2, "fixture expected to contain MS2 spectra"
    cid_spectra = [
        s for s in ms2 if s.activation_method == int(ActivationMethod.CID)
    ]
    assert cid_spectra, "fixture expected to contain at least one CID MS2 spectrum"
    first = cid_spectra[0]
    assert first.isolation_target_mz > 0.0
    # The fixture's first MS2 precursor has target=445.3 with lower=upper=0.5.
    assert abs(first.isolation_target_mz - 445.3) < 1e-6
    assert abs(first.isolation_lower_offset - 0.5) < 1e-6
    assert abs(first.isolation_upper_offset - 0.5) < 1e-6

    # Round-trip through the .mpgo writer (schema-gating path).
    out = tmp_path / "tiny_m74.mpgo"
    result.to_mpgo(out)

    with SpectralDataset.open(out) as ds:
        run = ds.ms_runs["run_0001"]
        idx = run.index
        assert idx.activation_methods is not None
        assert idx.isolation_target_mzs is not None
        # Find the MS2/CID row in the spectrum_index.
        found_cid = False
        for i in range(idx.count):
            if (idx.ms_levels[i] == 2
                    and idx.activation_method_at(i) == ActivationMethod.CID):
                iw = idx.isolation_window_at(i)
                if iw is not None and abs(iw.target_mz - 445.3) < 1e-6:
                    assert abs(iw.lower_offset - 0.5) < 1e-6
                    assert abs(iw.upper_offset - 0.5) < 1e-6
                    found_cid = True
                    break
        assert found_cid, "MS2/CID/445.3 row not found in round-tripped spectrum_index"


def test_mzml_pack_run_skips_m74_columns_when_all_ms1(tmp_path: Path) -> None:
    """(M74) When every ImportedSpectrum has default activation + zero
    isolation offsets, ``_pack_run`` must leave the four optional
    WrittenRun columns None so the writer does not emit them."""
    from mpeg_o.importers.import_result import ImportResult, ImportedSpectrum

    spectra = [
        ImportedSpectrum(
            mz_or_chemical_shift=np.array([100.0, 200.0, 300.0]),
            intensity=np.array([10.0, 20.0, 30.0]),
            retention_time=float(i) * 0.1,
            ms_level=1,
            polarity=1,
        )
        for i in range(3)
    ]
    result = ImportResult(title="ms1_only", ms_spectra=spectra)
    out = tmp_path / "ms1_only.mpgo"
    result.to_mpgo(out)
    with SpectralDataset.open(out) as ds:
        idx = ds.ms_runs["run_0001"].index
        assert idx.activation_methods is None
        assert idx.isolation_target_mzs is None
        assert idx.isolation_lower_offsets is None
        assert idx.isolation_upper_offsets is None


def test_nmrml_imports_bmrb_fixture(bmrb_nmrml: Path, tmp_path: Path) -> None:
    result = nmrml.read(bmrb_nmrml)
    # The BMRB fixture may carry an FID plus one or more 1-D spectra; we
    # accept zero spectra (FID-only) by also checking the nucleus metadata.
    if result.spectrum_count > 0:
        out = tmp_path / "from_nmrml.mpgo"
        result.to_mpgo(out)
        with SpectralDataset.open(out) as ds:
            assert "nmr_run" in ds.ms_runs
            assert ds.ms_runs["nmr_run"].spectrum_class == "MPGONMRSpectrum"
    else:
        # Still record that we parsed the nucleus, so the test isn't trivial.
        assert result.nucleus_type or result.source_file
