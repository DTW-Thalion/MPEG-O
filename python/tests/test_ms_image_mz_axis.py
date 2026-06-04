"""Cross-language parity test: MSImage.mz_axis round-trip via standalone API."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import MSImage
from ttio.enums import ImageKind
from ttio.providers import open_provider


def _build_image(w: int, h: int, sp: int) -> MSImage:
    cube = np.arange(h * w * sp, dtype=np.float64).reshape(h, w, sp) * 0.1
    mz = np.linspace(100.0, 100.0 + (sp - 1) * 100.0, sp)
    return MSImage(
        width=w, height=h, spectral_points=sp,
        intensity=cube,
        mz_axis=mz,
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
    )


def test_mz_axis_round_trip(tmp_path: Path) -> None:
    img = _build_image(4, 3, 8)
    out = tmp_path / "mz_axis.tio"
    with open_provider(str(out), provider="hdf5", mode="w") as sp:
        root = sp.root_group()
        study = root.create_group("study")
        img.write_to(study)
    with open_provider(str(out), provider="hdf5", mode="r") as sp:
        root = sp.root_group()
        study = root.open_group("study")
        read = MSImage.read_from(study)
    assert read is not None
    np.testing.assert_array_equal(read.mz_axis, img.mz_axis)
    np.testing.assert_array_equal(read.intensity, img.intensity)


def test_legacy_file_returns_empty_mz_axis(tmp_path: Path) -> None:
    """A file written without mz_axis reads back with an empty axis."""
    img = MSImage(
        width=2, height=2, spectral_points=3,
        intensity=np.zeros((2, 2, 3), dtype=np.float64),
        # mz_axis defaults to empty
        pixel_size_x=1.0, pixel_size_y=1.0, scan_pattern="raster",
    )
    out = tmp_path / "legacy.tio"
    with open_provider(str(out), provider="hdf5", mode="w") as sp:
        root = sp.root_group()
        study = root.create_group("study")
        img.write_to(study)
    with open_provider(str(out), provider="hdf5", mode="r") as sp:
        root = sp.root_group()
        study = root.open_group("study")
        read = MSImage.read_from(study)
    assert read is not None
    assert read.mz_axis.size == 0


def test_mz_axis_length_mismatch_rejected() -> None:
    cube = np.zeros((2, 2, 3), dtype=np.float64)
    bad_mz = np.linspace(0.0, 1.0, 4)  # wrong length (4 vs 3)
    with pytest.raises(ValueError, match="mz_axis"):
        MSImage(
            width=2, height=2, spectral_points=3,
            intensity=cube, mz_axis=bad_mz,
        )


def test_to_pixel_spectra_continuous_mode() -> None:
    img = _build_image(2, 2, 3)
    pixels = img.to_pixel_spectra()
    assert len(pixels) == 4
    # Pixel (row=0, col=0)
    p0 = pixels[0]
    assert p0.x == 0 and p0.y == 0
    np.testing.assert_array_equal(p0.mz, img.mz_axis)
    np.testing.assert_array_equal(p0.intensity, img.intensity[0, 0])
    # Pixel (row=1, col=1)
    p3 = pixels[3]
    assert p3.x == 1 and p3.y == 1
    np.testing.assert_array_equal(p3.mz, img.mz_axis)
    np.testing.assert_array_equal(p3.intensity, img.intensity[1, 1])
    # Continuous mode contract: pixels share the SAME mz array object,
    # not just equal values. Downstream imzML writers rely on this.
    assert p0.mz is img.mz_axis
    assert p3.mz is img.mz_axis


def test_to_pixel_spectra_raises_with_empty_axis() -> None:
    img = MSImage(
        width=2, height=2, spectral_points=3,
        intensity=np.zeros((2, 2, 3), dtype=np.float64),
    )
    with pytest.raises(RuntimeError, match="mz_axis"):
        img.to_pixel_spectra()


def test_spectral_dataset_image_property(tmp_path: Path) -> None:
    """SpectralDataset.write_minimal(image=...) persists the cube;
    SpectralDataset.image property reads it back."""
    from ttio import SpectralDataset

    img = _build_image(2, 2, 4)
    out = tmp_path / "ds_with_image.tio"
    SpectralDataset.write_minimal(
        out, title="img-test", isa_investigation_id="",
        runs={}, image=img,
    )

    with SpectralDataset.open(out) as ds:
        materialised = ds.image_for_kind(ImageKind.MS)
        assert materialised is not None
        assert materialised.width == 2
        np.testing.assert_array_equal(materialised.mz_axis, img.mz_axis)


def test_spectral_dataset_image_property_returns_none_when_absent(tmp_path: Path) -> None:
    from ttio import SpectralDataset
    out = tmp_path / "no_image.tio"
    SpectralDataset.write_minimal(out, title="", isa_investigation_id="", runs={})
    with SpectralDataset.open(out) as ds:
        assert ds.image_for_kind(ImageKind.MS) is None


def test_zero_dim_image_with_mz_axis_rejected() -> None:
    """Empty-default shortcut must not bypass mz_axis validation."""
    with pytest.raises(ValueError, match="mz_axis"):
        MSImage(width=0, height=0, spectral_points=0,
                mz_axis=np.zeros(5))


def test_spectral_dataset_image_property_caches(tmp_path: Path) -> None:
    """Repeated .image calls return the same cached MSImage object."""
    from ttio import SpectralDataset
    img = _build_image(2, 2, 4)
    out = tmp_path / "cached.tio"
    SpectralDataset.write_minimal(
        out, title="cache", isa_investigation_id="",
        runs={}, image=img,
    )
    with SpectralDataset.open(out) as ds:
        first = ds.image_for_kind(ImageKind.MS)
        second = ds.image_for_kind(ImageKind.MS)
        assert first is second, "second call should return cached object"
