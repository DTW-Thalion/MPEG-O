"""IPT1 fence test: shared ``Image`` base + ``ImageKind`` discriminator.

Asserts (1) MS/Raman/IR subclass the new ``Image`` base, (2) the
``kind`` / ``spectral_axis`` / ``spectral_axis_kind`` discriminators
are wired correctly, and (3) byte-identical .tio round-trips for all
three image kinds are preserved (the refactor invariant).
"""
from __future__ import annotations

import numpy as np

from ttio.enums import IRMode, ImageKind, SpectralAxisKind
from ttio.image import Image
from ttio.ir_image import IRImage
from ttio.ms_image import MSImage
from ttio.providers import open_provider
from ttio.raman_image import RamanImage


def _ms() -> MSImage:
    cube = np.arange(2 * 3 * 4, dtype=np.float64).reshape(3, 2, 4)  # (h,w,sp)
    return MSImage(
        width=2, height=3, spectral_points=4, intensity=cube,
        mz_axis=np.linspace(100, 110, 4), pixel_size_x=1.0,
        pixel_size_y=2.0, scan_pattern="raster", title="t",
        isa_investigation_id="inv1",
    )


def _raman() -> RamanImage:
    cube = np.arange(3 * 3 * 5, dtype=np.float64).reshape(3, 3, 5) * 0.5
    wn = np.array([1000.0, 1100.0, 1200.0, 1300.0, 1400.0], dtype=np.float64)
    return RamanImage(
        width=3, height=3, spectral_points=5, intensity=cube,
        wavenumbers=wn, pixel_size_x=10.0, pixel_size_y=11.0,
        scan_pattern="raster", excitation_wavelength_nm=785.0,
        laser_power_mw=50.0, title="r", isa_investigation_id="inv2",
    )


def _ir() -> IRImage:
    cube = np.arange(3 * 3 * 5, dtype=np.float64).reshape(3, 3, 5) * 0.5
    wn = np.array([1000.0, 1100.0, 1200.0, 1300.0, 1400.0], dtype=np.float64)
    return IRImage(
        width=3, height=3, spectral_points=5, intensity=cube,
        wavenumbers=wn, pixel_size_x=10.0, pixel_size_y=11.0,
        scan_pattern="raster", mode=IRMode.ABSORBANCE,
        resolution_cm_inv=4.0, title="i", isa_investigation_id="inv3",
    )


def test_subclass_of_image() -> None:
    assert isinstance(_ms(), Image)
    assert isinstance(_raman(), Image)
    assert isinstance(_ir(), Image)


def test_kind_and_axis() -> None:
    m = _ms()
    assert m.kind == ImageKind.MS
    assert m.spectral_axis is m.mz_axis
    assert m.spectral_axis_kind == SpectralAxisKind.MZ

    r = _raman()
    assert r.kind == ImageKind.RAMAN
    assert r.spectral_axis is r.wavenumbers
    assert r.spectral_axis_kind == SpectralAxisKind.WAVENUMBER

    i = _ir()
    assert i.kind == ImageKind.IR
    assert i.spectral_axis is i.wavenumbers
    assert i.spectral_axis_kind == SpectralAxisKind.WAVENUMBER


def _roundtrip(img, cls):
    """Write ``img`` to a study group then read it back via ``cls``."""
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as d:
        out = str(Path(d) / "image.tio")
        with open_provider(out, provider="hdf5", mode="w") as sp:
            study = sp.root_group().create_group("study")
            img.write_to(study)
        with open_provider(out, provider="hdf5", mode="r") as sp:
            study = sp.root_group().open_group("study")
            return cls.read_from(study)


def _assert_common_equal(read, orig) -> None:
    assert read is not None
    assert np.array_equal(read.intensity, orig.intensity)
    assert read.width == orig.width
    assert read.height == orig.height
    assert read.spectral_points == orig.spectral_points
    assert read.pixel_size_x == orig.pixel_size_x
    assert read.pixel_size_y == orig.pixel_size_y
    assert read.scan_pattern == orig.scan_pattern
    assert read.tile_size == orig.tile_size


def test_roundtrip_ms() -> None:
    orig = _ms()
    read = _roundtrip(orig, MSImage)
    _assert_common_equal(read, orig)
    np.testing.assert_array_equal(read.mz_axis, orig.mz_axis)
    assert read.spectral_axis_kind == SpectralAxisKind.MZ


def test_roundtrip_raman() -> None:
    orig = _raman()
    read = _roundtrip(orig, RamanImage)
    _assert_common_equal(read, orig)
    np.testing.assert_array_equal(read.wavenumbers, orig.wavenumbers)
    assert read.excitation_wavelength_nm == orig.excitation_wavelength_nm
    assert read.laser_power_mw == orig.laser_power_mw
    assert read.spectral_axis_kind == SpectralAxisKind.WAVENUMBER


def test_roundtrip_ir() -> None:
    orig = _ir()
    read = _roundtrip(orig, IRImage)
    _assert_common_equal(read, orig)
    np.testing.assert_array_equal(read.wavenumbers, orig.wavenumbers)
    assert read.mode == orig.mode
    assert read.resolution_cm_inv == orig.resolution_cm_inv
    assert read.spectral_axis_kind == SpectralAxisKind.WAVENUMBER
