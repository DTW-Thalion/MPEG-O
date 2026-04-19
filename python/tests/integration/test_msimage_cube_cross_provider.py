"""Cross-provider MSImage cube round-trip (v0.9 M64.5 phase C).

The existing ``test_nd_dataset_cross_backend.py`` proves
:meth:`StorageGroup.create_dataset_nd` is implemented for all four
providers. This file pins the MSImage-shaped usage — a cube of
``[height, width, spectral_points]`` float64 values written through
:class:`StorageProvider` and read back with bit-identical byte
stream.

A full MSImage writer on top of ``SpectralDataset.write_minimal``
remains a v1.0+ item (the M64.5 phase C survey confirmed no writer
exists yet in ``src/mpeg_o/``); once that ships the cube flows
through this same primitive without test churn.
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import numpy as np
import pytest

from mpeg_o.enums import Precision
from mpeg_o.providers import open_provider

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _provider_matrix import (  # type: ignore[import-not-found]
    PROVIDERS as _PROVIDERS,
    provider_url as _provider_url,
)


def _provider_for_cube(provider: str, tmp_path: Path) -> tuple[str, str]:
    """Return (url, mode-for-reopen) the cube test can write into.

    All four providers accept write followed by fresh-instance read
    through :func:`open_provider`.
    """
    return _provider_url(provider, tmp_path, "cube"), "r"


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_msimage_cube_nd_roundtrip(provider: str, tmp_path: Path) -> None:
    """Write a small 3-D intensity cube, read it back, compare bytes."""
    rng = np.random.default_rng(42)
    h, w, sp = 4, 5, 8
    cube = rng.uniform(0.0, 1e6, size=(h, w, sp)).astype(np.float64)

    url, read_mode = _provider_for_cube(provider, tmp_path)

    with open_provider(url, provider=provider, mode="w") as sp_write:
        root = sp_write.root_group()
        study = root.create_group("study")
        img = study.create_group("image_cube")
        ds = img.create_dataset_nd(
            "intensity",
            Precision.FLOAT64,
            shape=(h, w, sp),
        )
        ds.write(cube)
        # Companion attributes the future MSImage writer will persist.
        img.set_attribute("width", int(w))
        img.set_attribute("height", int(h))
        img.set_attribute("spectral_points", int(sp))

    with open_provider(url, provider=provider, mode=read_mode) as sp_read:
        root = sp_read.root_group()
        study = root.open_group("study")
        img = study.open_group("image_cube")
        assert int(img.get_attribute("height")) == h
        assert int(img.get_attribute("width")) == w
        assert int(img.get_attribute("spectral_points")) == sp
        readback = np.asarray(img.open_dataset("intensity").read())
        assert readback.shape == (h, w, sp)
        np.testing.assert_array_equal(readback, cube)
