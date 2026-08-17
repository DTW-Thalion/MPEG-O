"""Extendable datasets (append) across the four storage providers."""
from __future__ import annotations

import numpy as np
import pytest

from ttio.enums import Precision
from ttio.providers.base import CompoundField, CompoundFieldKind
from ttio.providers.hdf5 import Hdf5Provider
from ttio.providers.memory import MemoryProvider
from ttio.providers.sqlite import SqliteProvider
from ttio.providers.zarr import ZarrProvider

PROVIDERS = ["hdf5", "zarr", "memory", "sqlite"]


def _open(which, tmp_path, name="a"):
    if which == "hdf5":
        return Hdf5Provider.open(str(tmp_path / f"{name}.tio"), mode="w")
    if which == "zarr":
        return ZarrProvider.open(str(tmp_path / f"{name}.zarr"), mode="w")
    if which == "memory":
        return MemoryProvider.open(f"memory://ext-{name}-{tmp_path.name}", mode="w")
    return SqliteProvider.open(str(tmp_path / f"{name}.sqlite"), mode="w")


@pytest.mark.parametrize("which", PROVIDERS)
def test_append_primitive(tmp_path, which):
    prov = _open(which, tmp_path)
    root = prov.root_group()
    ds = root.create_dataset("x", Precision.UINT8, 0, chunk_size=4, extendable=True)
    assert ds.extendable and ds.length == 0
    ds.append(np.arange(5, dtype=np.uint8))
    ds.append(np.arange(5, 9, dtype=np.uint8))
    assert ds.length == 9
    assert ds.read(3, 4).tolist() == [3, 4, 5, 6]
    assert ds.read().tolist() == list(range(9))
    prov.close()


@pytest.mark.parametrize("which", PROVIDERS)
def test_append_compound(tmp_path, which):
    prov = _open(which, tmp_path)
    root = prov.root_group()
    fields = [CompoundField("a", CompoundFieldKind.UINT64),
              CompoundField("b", CompoundFieldKind.UINT32)]
    ds = root.create_compound_dataset("idx", fields, 0, extendable=True, chunk_rows=2)
    ds.append([{"a": 1, "b": 2}, {"a": 3, "b": 4}])
    ds.append([{"a": 5, "b": 6}])
    rows = ds.read_rows()
    assert [(int(r["a"]), int(r["b"])) for r in rows] == [(1, 2), (3, 4), (5, 6)]
    assert ds.length == 3
    prov.close()


@pytest.mark.parametrize("which", PROVIDERS)
def test_write_slice(tmp_path, which):
    prov = _open(which, tmp_path)
    root = prov.root_group()
    ds = root.create_dataset("x", Precision.UINT8, 0, chunk_size=4, extendable=True)
    ds.append(np.zeros(10, dtype=np.uint8))
    ds.write_slice(2, np.array([7, 8, 9], dtype=np.uint8))
    assert ds.read().tolist() == [0, 0, 7, 8, 9, 0, 0, 0, 0, 0]
    prov.close()


def test_non_extendable_rejects_append(tmp_path):
    root = MemoryProvider.open("memory://ext-neg", mode="w").root_group()
    ds = root.create_dataset("x", Precision.UINT8, 3, chunk_size=4)
    with pytest.raises(TypeError):
        ds.append(np.zeros(1, dtype=np.uint8))
    with pytest.raises(ValueError, match="chunk_size"):
        root.create_dataset("y", Precision.UINT8, 0, extendable=True)


def test_hdf5_extendable_survives_reopen(tmp_path):
    p = str(tmp_path / "r.tio")
    prov = Hdf5Provider.open(p, mode="w")
    ds = prov.root_group().create_dataset("x", Precision.FLOAT64, 0, chunk_size=1024, extendable=True)
    ds.append(np.arange(3000, dtype="<f8"))
    prov.close()
    prov = Hdf5Provider.open(p, mode="r")
    ds = prov.root_group().open_dataset("x")
    assert ds.length == 3000 and float(ds.read(2999, 1)[0]) == 2999.0
    assert ds.extendable
    prov.close()
