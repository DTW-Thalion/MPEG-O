"""IPT2: SpectralDataset's uniform image collection.

The three typed lazy accessors (``image`` / ``raman_image`` /
``ir_image``) are replaced by a uniform :meth:`image_for_kind` lookup
and an :attr:`images` collection keyed by :class:`ttio.enums.ImageKind`.
The lazy per-kind read+cache behaviour is preserved; the old accessors
are removed.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import MSImage, SpectralDataset
from ttio.enums import ImageKind


def _build_image(w: int, h: int, sp: int) -> MSImage:
    cube = np.arange(h * w * sp, dtype=np.float64).reshape(h, w, sp) * 0.1
    mz = np.linspace(100.0, 100.0 + (sp - 1) * 100.0, sp)
    return MSImage(
        width=w, height=h, spectral_points=sp,
        intensity=cube,
        mz_axis=mz,
        pixel_size_x=10.0, pixel_size_y=10.0, scan_pattern="raster",
    )


def _write_ms_only(out: Path) -> None:
    img = _build_image(2, 2, 4)
    SpectralDataset.write_minimal(
        out, title="img-test", isa_investigation_id="",
        runs={}, image=img,
    )


def test_image_for_kind_returns_present_kind(tmp_path: Path) -> None:
    out = tmp_path / "ms_only.tio"
    _write_ms_only(out)
    with SpectralDataset.open(out) as ds:
        ms = ds.image_for_kind(ImageKind.MS)
        assert ms is not None
        assert isinstance(ms, MSImage)
        assert ms.width == 2


def test_image_for_kind_absent_kind_is_none(tmp_path: Path) -> None:
    out = tmp_path / "ms_only.tio"
    _write_ms_only(out)
    with SpectralDataset.open(out) as ds:
        assert ds.image_for_kind(ImageKind.RAMAN) is None
        assert ds.image_for_kind(ImageKind.IR) is None


def test_images_collection_contains_only_present_kinds(tmp_path: Path) -> None:
    out = tmp_path / "ms_only.tio"
    _write_ms_only(out)
    with SpectralDataset.open(out) as ds:
        images = ds.images
        assert isinstance(images, dict)
        assert set(images.keys()) == {ImageKind.MS}
        assert isinstance(images[ImageKind.MS], MSImage)


def test_image_for_kind_caches(tmp_path: Path) -> None:
    """Repeated image_for_kind calls return the same cached object."""
    out = tmp_path / "ms_only.tio"
    _write_ms_only(out)
    with SpectralDataset.open(out) as ds:
        first = ds.image_for_kind(ImageKind.MS)
        second = ds.image_for_kind(ImageKind.MS)
        assert first is second, "second call should return cached object"


def test_image_for_kind_rejects_unknown_kind(tmp_path: Path) -> None:
    out = tmp_path / "ms_only.tio"
    _write_ms_only(out)
    with SpectralDataset.open(out) as ds:
        with pytest.raises(ValueError, match="unknown ImageKind"):
            ds.image_for_kind(object())  # type: ignore[arg-type]


def test_old_accessors_removed(tmp_path: Path) -> None:
    """The typed image/raman_image/ir_image properties are gone."""
    out = tmp_path / "ms_only.tio"
    _write_ms_only(out)
    with SpectralDataset.open(out) as ds:
        for attr in ("image", "raman_image", "ir_image"):
            assert not hasattr(ds, attr), (
                f"old accessor {attr!r} must be removed"
            )
