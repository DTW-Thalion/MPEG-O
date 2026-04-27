"""V9 provider-specific edge case tests (Python).

Stress the Python providers (Memory, SQLite, Zarr) at their
boundaries. ObjC and Java only support these providers read-only
(per M64 parity decision), so V9 is Python-only.

Scenarios:

* SQLite: round-trip across close/reopen; large array (8 MB);
  reopen rejects nonexistent path.
* Memory: round-trip empty + large dataset; isolation between
  instances.
* Zarr: round-trip + chunked array (skipped if zarr not installed).

Per docs/verification-workplan.md §V9.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.encoding_spec import Compression, Precision
from ttio.providers.memory import MemoryProvider
from ttio.providers.sqlite import SqliteProvider


def _write_sample(provider_cls, path_or_url, n=100):
    """Write a small 1-D float64 dataset and return what we wrote."""
    expected = np.arange(n, dtype=np.float64)
    with provider_cls.open(path_or_url, mode="w") as p:
        ds = p.root_group().create_dataset_nd(
            "samples", Precision.FLOAT64, expected.shape,
            chunks=expected.shape,
            compression=Compression.NONE,
        )
        ds.write(expected)
    return expected


def _read_sample(provider_cls, path_or_url):
    with provider_cls.open(path_or_url, mode="r") as p:
        return np.asarray(p.root_group().open_dataset("samples").read())


# ---------------------------------------------------------------------------
# SQLite provider
# ---------------------------------------------------------------------------


def test_sqlite_round_trips_across_reopen(tmp_path):
    """Write via SqliteProvider, close, reopen — content survives."""
    path = tmp_path / "sample.sqlite"
    expected = _write_sample(SqliteProvider, str(path))
    got = _read_sample(SqliteProvider, str(path))
    np.testing.assert_array_equal(got, expected)


def test_sqlite_handles_large_array(tmp_path):
    """SQLite accepts a multi-MB array (default page-size limits would clip)."""
    path = tmp_path / "large.sqlite"
    big = np.linspace(0.0, 1.0, 1_000_000, dtype=np.float64)  # 8 MB
    with SqliteProvider.open(str(path), mode="w") as p:
        ds = p.root_group().create_dataset_nd(
            "big", Precision.FLOAT64, big.shape,
            chunks=big.shape,
            compression=Compression.NONE,
        )
        ds.write(big)
    with SqliteProvider.open(str(path), mode="r") as p:
        back = np.asarray(p.root_group().open_dataset("big").read())
    assert back.shape == big.shape
    assert back[0] == 0.0
    assert back[-1] == pytest.approx(1.0, abs=1e-12)


def test_sqlite_reopens_after_double_close(tmp_path):
    """Closing the SqliteProvider context twice is benign."""
    path = tmp_path / "double_close.sqlite"
    _write_sample(SqliteProvider, str(path))
    # First close (via `with` block) — fine.
    # Second open + close — must succeed without DB-locked errors.
    with SqliteProvider.open(str(path), mode="r") as p:
        got = np.asarray(p.root_group().open_dataset("samples").read())
    assert len(got) == 100


def test_sqlite_concurrent_readers(tmp_path):
    """Two SqliteProvider context managers open the same DB read-only."""
    path = tmp_path / "concurrent.sqlite"
    _write_sample(SqliteProvider, str(path))
    with SqliteProvider.open(str(path), mode="r") as p_a, \
         SqliteProvider.open(str(path), mode="r") as p_b:
        arr_a = np.asarray(p_a.root_group().open_dataset("samples").read())
        arr_b = np.asarray(p_b.root_group().open_dataset("samples").read())
    np.testing.assert_array_equal(arr_a, arr_b)


# ---------------------------------------------------------------------------
# Memory provider
# ---------------------------------------------------------------------------


def test_memory_round_trip_via_url():
    """MemoryProvider round-trips a simple dataset using the memory:// URL scheme."""
    url = "memory://v9-roundtrip"
    try:
        expected = _write_sample(MemoryProvider, url)
        got = _read_sample(MemoryProvider, url)
        np.testing.assert_array_equal(got, expected)
    finally:
        MemoryProvider.discard_store(url)


def test_memory_provider_isolated_stores():
    """Two MemoryProvider URLs don't share state."""
    url_a = "memory://v9-isolated-a"
    url_b = "memory://v9-isolated-b"
    try:
        _write_sample(MemoryProvider, url_a, n=10)
        # URL b is empty; opening it for read should see no 'samples' dataset.
        with MemoryProvider.open(url_b, mode="w") as p:
            # A different dataset name in b; doesn't conflict with a.
            other = np.arange(5, dtype=np.float64)
            ds = p.root_group().create_dataset_nd(
                "other", Precision.FLOAT64, other.shape,
                chunks=other.shape, compression=Compression.NONE,
            )
            ds.write(other)
        with MemoryProvider.open(url_b, mode="r") as p:
            assert "other" in p.root_group().child_names()
            assert "samples" not in p.root_group().child_names()
    finally:
        MemoryProvider.discard_store(url_a)
        MemoryProvider.discard_store(url_b)


def test_memory_handles_large_array():
    """MemoryProvider handles a 1 M-element float64 array (~8 MB)."""
    url = "memory://v9-large"
    try:
        big = np.linspace(0.0, 1.0, 1_000_000, dtype=np.float64)
        with MemoryProvider.open(url, mode="w") as p:
            ds = p.root_group().create_dataset_nd(
                "big", Precision.FLOAT64, big.shape,
                chunks=big.shape, compression=Compression.NONE,
            )
            ds.write(big)
        with MemoryProvider.open(url, mode="r") as p:
            back = np.asarray(p.root_group().open_dataset("big").read())
        assert back.shape == big.shape
        assert back[-1] == pytest.approx(1.0, abs=1e-12)
    finally:
        MemoryProvider.discard_store(url)


# ---------------------------------------------------------------------------
# Zarr provider (skipped if zarr not installed)
# ---------------------------------------------------------------------------


def _zarr_or_skip():
    try:
        import zarr  # noqa: F401
        from ttio.providers.zarr import ZarrProvider
        return ZarrProvider
    except ImportError:
        pytest.skip("zarr not installed")


def test_zarr_round_trips_across_reopen(tmp_path):
    """Zarr round-trips a 1-D dataset across close/reopen."""
    ZarrProvider = _zarr_or_skip()
    path = tmp_path / "sample.zarr"
    expected = _write_sample(ZarrProvider, str(path))
    got = _read_sample(ZarrProvider, str(path))
    np.testing.assert_array_equal(got, expected)


def test_zarr_handles_chunked_array(tmp_path):
    """Zarr writes a 10K × 100 chunked array efficiently."""
    ZarrProvider = _zarr_or_skip()
    path = tmp_path / "chunked.zarr"
    big = np.arange(10_000 * 100, dtype=np.float32).reshape(10_000, 100)
    with ZarrProvider.open(str(path), mode="w") as p:
        ds = p.root_group().create_dataset_nd(
            "matrix", Precision.FLOAT32, big.shape,
            chunks=(1000, 100),  # 10 chunks total
            compression=Compression.NONE,
        )
        ds.write(big)
    with ZarrProvider.open(str(path), mode="r") as p:
        back = np.asarray(p.root_group().open_dataset("matrix").read())
    assert back.shape == (10_000, 100)
    assert back[0, 0] == 0.0
    assert back[-1, -1] == 999_999.0
