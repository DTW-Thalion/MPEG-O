"""RamanImage HDF5 I/O round-trip tests (v1.2.0).

Mirror of test_ms_image_mz_axis.py, adapted for RamanImage semantics:
wavenumbers axis, excitation_wavelength_nm, laser_power_mw, and the
PR #31 native-double fix for pixel_size_x/y.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset
from ttio.raman_image import RamanImage
from ttio.providers import open_provider


# ── helpers ─────────────────────────────────────────────────────────────────

def _build_raman_image(w: int = 4, h: int = 3, sp: int = 8) -> RamanImage:
    cube = np.arange(h * w * sp, dtype=np.float64).reshape(h, w, sp) * 0.5
    wn = np.linspace(800.0, 3500.0, sp)
    return RamanImage(
        width=w, height=h, spectral_points=sp,
        intensity=cube, wavenumbers=wn,
        pixel_size_x=5.0, pixel_size_y=5.0,
        scan_pattern="raster",
        excitation_wavelength_nm=785.0,
        laser_power_mw=10.0,
    )


# ── tests ────────────────────────────────────────────────────────────────────

def test_write_to_read_from_round_trip(tmp_path: Path) -> None:
    """Write a RamanImage, read it back, assert all fields equal."""
    img = _build_raman_image()
    out = tmp_path / "raman.tio"
    with open_provider(str(out), provider="hdf5", mode="w") as sp:
        root = sp.root_group()
        study = root.create_group("study")
        img.write_to(study)
    with open_provider(str(out), provider="hdf5", mode="r") as sp:
        root = sp.root_group()
        study = root.open_group("study")
        read = RamanImage.read_from(study)

    assert read is not None
    np.testing.assert_array_equal(read.wavenumbers, img.wavenumbers)
    np.testing.assert_array_equal(read.intensity, img.intensity)
    assert read.width == img.width
    assert read.height == img.height
    assert read.spectral_points == img.spectral_points
    assert read.pixel_size_x == pytest.approx(img.pixel_size_x)
    assert read.pixel_size_y == pytest.approx(img.pixel_size_y)
    assert read.scan_pattern == img.scan_pattern
    assert read.excitation_wavelength_nm == pytest.approx(img.excitation_wavelength_nm)
    assert read.laser_power_mw == pytest.approx(img.laser_power_mw)


def test_legacy_string_pixel_size_attr_still_reads(tmp_path: Path) -> None:
    """A file with pixel_size_x/y as string attrs (legacy form) reads back correctly."""
    import h5py
    out = tmp_path / "legacy_psize.tio"
    # Write manually with string attrs (old behaviour before PR #31 fix)
    with h5py.File(str(out), "w") as f:
        study = f.create_group("study")
        ic = study.create_group("raman_image_cube")
        ic.attrs["width"] = np.int64(2)
        ic.attrs["height"] = np.int64(2)
        ic.attrs["spectral_points"] = np.int64(3)
        ic.attrs["pixel_size_x"] = "10.0"    # legacy string form
        ic.attrs["pixel_size_y"] = "10.0"
        ic.attrs["excitation_wavelength_nm"] = "785.0"
        ic.attrs["laser_power_mw"] = "5.0"
        ic.attrs["scan_pattern"] = "raster"
        cube = np.zeros(2 * 2 * 3, dtype=np.float64)
        ic.create_dataset("intensity", data=cube.reshape(2, 2, 3))
        ic.create_dataset("wavenumbers", data=np.linspace(800.0, 2000.0, 3))

    with open_provider(str(out), provider="hdf5", mode="r") as sp:
        root = sp.root_group()
        study = root.open_group("study")
        read = RamanImage.read_from(study)

    assert read is not None
    assert read.pixel_size_x == pytest.approx(10.0)
    assert read.pixel_size_y == pytest.approx(10.0)
    assert read.excitation_wavelength_nm == pytest.approx(785.0)
    assert read.laser_power_mw == pytest.approx(5.0)


def test_wavenumbers_length_mismatch_rejected() -> None:
    """wavenumbers length not matching spectral_points raises ValueError."""
    cube = np.zeros((2, 2, 3), dtype=np.float64)
    bad_wn = np.linspace(800.0, 3500.0, 4)   # wrong length (4 vs 3)
    with pytest.raises(ValueError, match="wavenumbers"):
        RamanImage(
            width=2, height=2, spectral_points=3,
            intensity=cube, wavenumbers=bad_wn,
        )


def test_spectral_dataset_raman_image_property(tmp_path: Path) -> None:
    """SpectralDataset.write_minimal(raman_image=...) writes;
    SpectralDataset.open(...).raman_image reads back."""
    img = _build_raman_image()
    out = tmp_path / "ds_raman.tio"
    SpectralDataset.write_minimal(
        out, title="raman-test", isa_investigation_id="",
        runs={}, raman_image=img,
    )
    with SpectralDataset.open(out) as ds:
        read = ds.raman_image
    assert read is not None
    assert read.width == img.width
    np.testing.assert_array_equal(read.wavenumbers, img.wavenumbers)
    assert read.excitation_wavelength_nm == pytest.approx(img.excitation_wavelength_nm)
    assert read.laser_power_mw == pytest.approx(img.laser_power_mw)


def test_spectral_dataset_raman_image_property_returns_none_when_absent(tmp_path: Path) -> None:
    """No raman_image group → property returns None."""
    out = tmp_path / "no_raman.tio"
    SpectralDataset.write_minimal(out, title="", isa_investigation_id="", runs={})
    with SpectralDataset.open(out) as ds:
        assert ds.raman_image is None


def test_spectral_dataset_raman_image_property_caches(tmp_path: Path) -> None:
    """Repeated .raman_image calls return the same cached object."""
    img = _build_raman_image()
    out = tmp_path / "cached_raman.tio"
    SpectralDataset.write_minimal(
        out, title="cache", isa_investigation_id="",
        runs={}, raman_image=img,
    )
    with SpectralDataset.open(out) as ds:
        first = ds.raman_image
        second = ds.raman_image
        assert first is second, "second .raman_image call should return cached object"
