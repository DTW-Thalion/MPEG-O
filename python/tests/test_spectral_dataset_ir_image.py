"""Stage 5.2 (transport-spec v0.11, Deferral 1): verify that
:attr:`SpectralDataset.ir_image` exposes the third imaging modality as
a first-class accessor, mirroring :attr:`image` (MSImage) and
:attr:`raman_image` (RamanImage). Backs ``/study/ir_image_cube/``.

Python parity for Java's :class:`SpectralDatasetIRImageTest` (commit
``97fb065e``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset
from ttio.enums import IRMode, ImageKind
from ttio.ir_image import IRImage


def _build_ir_image(w: int = 4, h: int = 4, sp: int = 16) -> IRImage:
    """Mirrors Java's ``buildIRFixture``: a small absorbance cube
    with a deterministic intensity ramp."""
    cube = np.empty((h, w, sp), dtype=np.float64)
    for i in range(cube.size):
        flat = i
        cube.flat[flat] = i * 0.125
    wn = np.array([400.0 + i * 10.0 for i in range(sp)], dtype=np.float64)
    return IRImage(
        width=w, height=h, spectral_points=sp,
        intensity=cube, wavenumbers=wn,
        pixel_size_x=1.0, pixel_size_y=1.0,
        scan_pattern="raster",
        mode=IRMode.ABSORBANCE, resolution_cm_inv=8.0,
        title="IR map", isa_investigation_id="",
    )


def test_ir_image_accessor_round_trip(tmp_path: Path) -> None:
    """Write an IR image cube into a dataset via ``write_minimal``,
    reopen via :meth:`SpectralDataset.open`, and assert
    :attr:`SpectralDataset.ir_image` returns the materialised cube."""
    path = tmp_path / "ir_image_accessor.tio"
    img = _build_ir_image()
    SpectralDataset.write_minimal(
        path,
        title="IR accessor test",
        isa_investigation_id="ISA-IR-001",
        runs={},
        ir_image=img,
    )

    with SpectralDataset.open(path) as ds:
        read = ds.image_for_kind(ImageKind.IR)
        assert read is not None, (
            "ir_image must materialise /study/ir_image_cube"
        )
        assert read.width == img.width
        assert read.height == img.height
        assert read.spectral_points == img.spectral_points
        assert read.mode == IRMode.ABSORBANCE
        assert read.resolution_cm_inv == pytest.approx(8.0)
        assert read.scan_pattern == "raster"
        np.testing.assert_array_equal(read.wavenumbers, img.wavenumbers)
        np.testing.assert_array_equal(read.intensity, img.intensity)

        # Sibling accessors stay None since we wrote neither modality.
        assert ds.image_for_kind(ImageKind.MS) is None, (
            "image must be None when /study/image_cube absent"
        )
        assert ds.image_for_kind(ImageKind.RAMAN) is None, (
            "raman_image must be None when /study/raman_image_cube absent"
        )


def test_ir_image_accessor_none_when_absent(tmp_path: Path) -> None:
    """Empty dataset (no ir_image_cube on disk) yields
    :attr:`SpectralDataset.ir_image` == None."""
    path = tmp_path / "ir_image_absent.tio"
    SpectralDataset.write_minimal(
        path,
        title="no IR",
        isa_investigation_id="ISA-NONE",
        runs={},
    )

    with SpectralDataset.open(path) as ds:
        assert ds.image_for_kind(ImageKind.IR) is None, (
            "ir_image must be None when /study/ir_image_cube is absent"
        )


def test_ir_image_read_from_legacy_string_attrs(tmp_path: Path) -> None:
    """A file with ``pixel_size_x/y`` and ``resolution_cm_inv`` written
    as string attrs (legacy form) reads back correctly. Mirrors the
    PR #31 native-double fix lesson applied to IRImage."""
    import h5py
    out = tmp_path / "legacy_psize_ir.tio"
    with h5py.File(str(out), "w") as f:
        study = f.create_group("study")
        ic = study.create_group("ir_image_cube")
        ic.attrs["width"] = np.int64(2)
        ic.attrs["height"] = np.int64(2)
        ic.attrs["spectral_points"] = np.int64(3)
        ic.attrs["pixel_size_x"] = "5.0"    # legacy string form
        ic.attrs["pixel_size_y"] = "5.0"
        ic.attrs["resolution_cm_inv"] = "2.0"
        ic.attrs["ir_mode"] = np.int64(1)
        ic.attrs["scan_pattern"] = "raster"
        cube = np.arange(2 * 2 * 3, dtype=np.float64).reshape(2, 2, 3)
        ic.create_dataset("intensity", data=cube)
        ic.create_dataset(
            "wavenumbers",
            data=np.array([800.0, 900.0, 1000.0], dtype=np.float64),
        )

    from ttio.providers import open_provider
    with open_provider(str(out), provider="hdf5", mode="r") as sp:
        root = sp.root_group()
        study = root.open_group("study")
        read = IRImage.read_from(study)

    assert read is not None
    assert read.pixel_size_x == pytest.approx(5.0)
    assert read.pixel_size_y == pytest.approx(5.0)
    assert read.resolution_cm_inv == pytest.approx(2.0)
    assert read.mode == IRMode.ABSORBANCE
