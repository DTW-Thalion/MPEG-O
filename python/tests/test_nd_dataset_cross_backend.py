"""Cross-backend N-D (rank >= 2) dataset round-trip (v0.7 M45).

The provider protocol declares ``create_dataset_nd`` with an optional
``chunks`` hint. v0.6 shipped the HDF5 implementation; M45 verifies the
Memory and SQLite providers handle rank-2 and rank-3 arrays correctly —
the precondition for migrating MSImage cube writes off ``native_handle``
to the provider protocol (M44).

This test does not exercise MSImage itself. It writes synthetic 2-D
and 3-D arrays through each provider, reads them back, and asserts
element-for-element equality plus shape fidelity.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.enums import Compression, Precision
from ttio.providers.hdf5 import Hdf5Provider
from ttio.providers.memory import MemoryProvider
from ttio.providers.sqlite import SqliteProvider


def _build_3d_cube() -> np.ndarray:
    """Rank-3 float64 cube shaped like a small MSImage
    (height × width × spectral_points)."""
    h, w, s = 4, 5, 6
    # Deterministic pattern; non-trivial values at each axis so a
    # transposed or mis-reshaped read shows up immediately.
    arr = np.zeros((h, w, s), dtype="<f8")
    for i in range(h):
        for j in range(w):
            for k in range(s):
                arr[i, j, k] = i * 100 + j * 10 + k + 0.5
    return arr


def _build_2d_slab() -> np.ndarray:
    """Rank-2 int32 slab."""
    return np.arange(4 * 6, dtype="<i4").reshape(4, 6)


def _roundtrip_3d(provider_factory, path_or_url: str) -> np.ndarray:
    cube = _build_3d_cube()
    with provider_factory.open(path_or_url, mode="w") as p:
        ds = p.root_group().create_dataset_nd(
            "cube", Precision.FLOAT64, cube.shape,
            chunks=(1, cube.shape[1], cube.shape[2]),
            compression=Compression.NONE,
        )
        ds.write(cube)
        assert ds.shape == cube.shape, (
            f"write-side shape mismatch: ds.shape={ds.shape}, "
            f"cube.shape={cube.shape}"
        )
    with provider_factory.open(path_or_url, mode="r") as p:
        got = p.root_group().open_dataset("cube").read()
    return np.asarray(got)


def _roundtrip_2d(provider_factory, path_or_url: str) -> np.ndarray:
    slab = _build_2d_slab()
    with provider_factory.open(path_or_url, mode="w") as p:
        ds = p.root_group().create_dataset_nd(
            "slab", Precision.INT32, slab.shape,
        )
        ds.write(slab)
    with provider_factory.open(path_or_url, mode="r") as p:
        got = p.root_group().open_dataset("slab").read()
    return np.asarray(got)


# ── Rank-3 cross-backend identity ────────────────────────────────────


def test_rank3_cube_roundtrip_hdf5(tmp_path: Path) -> None:
    path = tmp_path / "cube.h5"
    got = _roundtrip_3d(Hdf5Provider, str(path))
    expected = _build_3d_cube()
    assert got.shape == expected.shape
    np.testing.assert_array_equal(got, expected)


def test_rank3_cube_roundtrip_memory() -> None:
    url = "memory://m45-rank3"
    try:
        got = _roundtrip_3d(MemoryProvider, url)
        expected = _build_3d_cube()
        assert got.shape == expected.shape
        np.testing.assert_array_equal(got, expected)
    finally:
        MemoryProvider.discard_store(url)


def test_rank3_cube_roundtrip_sqlite(tmp_path: Path) -> None:
    path = tmp_path / "cube.tio.sqlite"
    got = _roundtrip_3d(SqliteProvider, str(path))
    expected = _build_3d_cube()
    assert got.shape == expected.shape
    np.testing.assert_array_equal(got, expected)


# ── Rank-2 cross-backend identity ────────────────────────────────────


def test_rank2_slab_roundtrip_hdf5(tmp_path: Path) -> None:
    path = tmp_path / "slab.h5"
    got = _roundtrip_2d(Hdf5Provider, str(path))
    np.testing.assert_array_equal(got, _build_2d_slab())


def test_rank2_slab_roundtrip_memory() -> None:
    url = "memory://m45-rank2"
    try:
        got = _roundtrip_2d(MemoryProvider, url)
        np.testing.assert_array_equal(got, _build_2d_slab())
    finally:
        MemoryProvider.discard_store(url)


def test_rank2_slab_roundtrip_sqlite(tmp_path: Path) -> None:
    path = tmp_path / "slab.tio.sqlite"
    got = _roundtrip_2d(SqliteProvider, str(path))
    np.testing.assert_array_equal(got, _build_2d_slab())


# ── Cross-backend byte/element identity ─────────────────────────────


def test_rank3_cross_backend_element_equality(tmp_path: Path) -> None:
    """The same logical cube, written through each provider, reads back
    as element-wise-equal arrays regardless of backend."""
    hdf5_bytes = _roundtrip_3d(Hdf5Provider, str(tmp_path / "x.h5"))

    url = "memory://m45-xbackend"
    try:
        mem_bytes = _roundtrip_3d(MemoryProvider, url)
    finally:
        MemoryProvider.discard_store(url)

    sql_bytes = _roundtrip_3d(SqliteProvider, str(tmp_path / "x.sqlite"))

    np.testing.assert_array_equal(hdf5_bytes, mem_bytes)
    np.testing.assert_array_equal(mem_bytes, sql_bytes)
    np.testing.assert_array_equal(hdf5_bytes, sql_bytes)


# ── Chunk-hint capability reporting ─────────────────────────────────


def test_chunk_hint_honoured_by_hdf5(tmp_path: Path) -> None:
    """Hdf5Provider reports supports_chunking=True and actually uses
    the chunks. Memory and SQLite report False (they ignore the hint)."""
    hdf5_p = Hdf5Provider.open(str(tmp_path / "chk.h5"), mode="w")
    try:
        assert hdf5_p.supports_chunking() is True
        assert hdf5_p.supports_compression() is True
    finally:
        hdf5_p.close()

    mem_p = MemoryProvider.open("memory://m45-caps", mode="w")
    try:
        assert mem_p.supports_chunking() is False
        assert mem_p.supports_compression() is False
    finally:
        mem_p.close()
        MemoryProvider.discard_store("memory://m45-caps")

    sq_p = SqliteProvider.open(str(tmp_path / "chk.sqlite"), mode="w")
    try:
        assert sq_p.supports_chunking() is False
        assert sq_p.supports_compression() is False
    finally:
        sq_p.close()


# ── Sanity: non-ndarray callers don't need to know about shape_json ─


@pytest.mark.parametrize("provider_name,factory,path_template", [
    ("hdf5",   Hdf5Provider,   "nd_sanity.h5"),
    ("memory", MemoryProvider, "memory://m45-sanity"),
    ("sqlite", SqliteProvider, "nd_sanity.tio.sqlite"),
])
def test_shape_attribute_preserved_across_backends(
        provider_name: str, factory, path_template: str,
        tmp_path: Path) -> None:
    """The dataset shape reported by the provider matches what we
    wrote, not a flattened or 1-D view."""
    target_shape = (3, 4, 5)
    arr = np.arange(3 * 4 * 5, dtype="<f8").reshape(target_shape)
    path = (str(tmp_path / path_template)
            if "://" not in path_template
            else path_template)
    try:
        with factory.open(path, mode="w") as p:
            ds = p.root_group().create_dataset_nd(
                "x", Precision.FLOAT64, target_shape)
            ds.write(arr)
            assert tuple(ds.shape) == target_shape

        with factory.open(path, mode="r") as p:
            ds = p.root_group().open_dataset("x")
            assert tuple(ds.shape) == target_shape
            # length() is axis-0 size by convention.
            assert ds.length == target_shape[0]
            got = ds.read()
            assert np.asarray(got).shape == target_shape
    finally:
        if provider_name == "memory":
            MemoryProvider.discard_store(path)
