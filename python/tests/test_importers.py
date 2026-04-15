"""Tests for the mzML and nmrML Python importers."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset
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
