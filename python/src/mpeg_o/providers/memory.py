"""In-memory storage provider — Milestone 39 Part D.

Holds the full group tree in Python dicts. Useful for tests and
transient pipelines where no file I/O is needed, and the existence of
this provider alongside :class:`~mpeg_o.providers.hdf5.Hdf5Provider`
is the proof that the abstraction actually works — if
``SpectralDataset`` functions identically over both, the protocol
contract is correct.

API status: Stable (Provisional per M39 — may change before v1.0).

Cross-language equivalents
--------------------------
Objective-C: ``MPGOMemoryProvider`` class
Java:        ``com.dtwthalion.mpgo.providers.MemoryProvider`` class

SPDX-License-Identifier: LGPL-3.0-or-later
"""
from __future__ import annotations

from typing import Any

import numpy as np

from ..enums import Compression, Precision
from .base import (
    CompoundField,
    CompoundFieldKind,
    StorageDataset,
    StorageGroup,
    StorageProvider,
)


# ── Open-registry of in-process stores ────────────────────────────────
# Keyed by an opaque URL like ``memory://some-name``. Lets two calls
# with the same URL see the same tree, which mirrors how file-backed
# providers behave.

_STORES: dict[str, "_MemoryRoot"] = {}


class _Dataset(StorageDataset):
    __slots__ = ("_name", "_precision", "_shape", "_chunks", "_fields",
                 "_data", "_attrs")

    def __init__(self, name: str, precision: Precision | None,
                 shape: tuple[int, ...],
                 fields: tuple[CompoundField, ...] | None,
                 chunks: tuple[int, ...] | None = None):
        self._name = name
        self._precision = precision
        self._shape = shape
        self._chunks = chunks
        self._fields = fields
        self._data: np.ndarray | None = None
        self._attrs: dict[str, Any] = {}

    @property
    def name(self) -> str:
        return self._name

    @property
    def precision(self) -> Precision | None:
        return self._precision

    @property
    def shape(self) -> tuple[int, ...]:
        return self._shape

    @property
    def chunks(self) -> tuple[int, ...] | None:
        return self._chunks

    @property
    def compound_fields(self) -> tuple[CompoundField, ...] | None:
        return self._fields

    def read(self, offset: int = 0, count: int = -1) -> np.ndarray:
        if self._data is None:
            return np.zeros(0, dtype=self._default_dtype())
        if len(self._shape) != 1:
            # N-D: hyperslab along axis 0 only
            if count < 0:
                return self._data[offset:]
            return self._data[offset: offset + count]
        if count < 0:
            return self._data[offset:]
        return self._data[offset: offset + count]

    def write(self, data: np.ndarray | list) -> None:
        # Compound datasets accept a list-of-dicts (per the storage
        # protocol contract); coerce into a structured array using
        # the dataset's compound dtype so :meth:`read_rows` round-trips.
        if self._fields is not None and isinstance(data, list):
            dt = _compound_dtype(self._fields)
            arr = np.zeros(len(data), dtype=dt)
            for i, rec in enumerate(data):
                for f in self._fields:
                    if f.name in rec:
                        arr[i][f.name] = rec[f.name]
        else:
            arr = np.asarray(data)
        if arr.shape != self._shape and arr.shape[0] != self._shape[0]:
            raise ValueError(
                f"dataset '{self._name}' expects shape {self._shape}, "
                f"got {arr.shape}")
        self._data = np.array(arr, copy=True)

    def has_attribute(self, name: str) -> bool:
        return name in self._attrs

    def get_attribute(self, name: str) -> Any:
        return self._attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        self._attrs[name] = value

    def delete_attribute(self, name: str) -> None:
        self._attrs.pop(name, None)

    def attribute_names(self) -> list[str]:
        return list(self._attrs.keys())

    def _default_dtype(self) -> np.dtype:
        if self._fields is not None:
            return _compound_dtype(self._fields)
        if self._precision is not None:
            return np.dtype(self._precision.numpy_dtype())
        return np.dtype("<f8")


class _Group(StorageGroup):
    __slots__ = ("_name", "_children", "_datasets", "_attrs")

    def __init__(self, name: str):
        self._name = name
        self._children: dict[str, "_Group"] = {}
        self._datasets: dict[str, _Dataset] = {}
        self._attrs: dict[str, Any] = {}

    @property
    def name(self) -> str:
        return self._name

    def child_names(self) -> list[str]:
        return list(self._children.keys()) + list(self._datasets.keys())

    def has_child(self, name: str) -> bool:
        return name in self._children or name in self._datasets

    def open_group(self, name: str) -> StorageGroup:
        if name not in self._children:
            raise KeyError(f"group '{name}' not found in '{self._name}'")
        return self._children[name]

    def create_group(self, name: str) -> StorageGroup:
        if self.has_child(name):
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        g = _Group(name)
        self._children[name] = g
        return g

    def delete_child(self, name: str) -> None:
        self._children.pop(name, None)
        self._datasets.pop(name, None)

    def open_dataset(self, name: str) -> StorageDataset:
        if name not in self._datasets:
            raise KeyError(f"dataset '{name}' not found in '{self._name}'")
        return self._datasets[name]

    def create_dataset(self, name: str, precision: Precision,
                       length: int, *,
                       chunk_size: int = 0,
                       compression: Compression = Compression.NONE,
                       compression_level: int = 6) -> StorageDataset:
        # chunk_size / compression args are ignored — in-memory store
        # has no chunk or filter pipeline.
        del compression, compression_level
        if self.has_child(name):
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        chunks = (chunk_size,) if chunk_size > 0 else None
        ds = _Dataset(name, precision, (length,), fields=None, chunks=chunks)
        self._datasets[name] = ds
        return ds

    def create_dataset_nd(self, name: str, precision: Precision,
                           shape: tuple[int, ...], *,
                           chunks: tuple[int, ...] | None = None,
                           compression: Compression = Compression.NONE,
                           compression_level: int = 6) -> StorageDataset:
        del compression, compression_level
        if self.has_child(name):
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        ds = _Dataset(name, precision, tuple(shape), fields=None,
                      chunks=tuple(chunks) if chunks else None)
        self._datasets[name] = ds
        return ds

    def create_compound_dataset(self, name: str,
                                 fields: list[CompoundField],
                                 count: int) -> StorageDataset:
        if self.has_child(name):
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        ds = _Dataset(name, precision=None, shape=(count,),
                      fields=tuple(fields))
        self._datasets[name] = ds
        return ds

    def has_attribute(self, name: str) -> bool:
        return name in self._attrs

    def get_attribute(self, name: str) -> Any:
        return self._attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        self._attrs[name] = value

    def delete_attribute(self, name: str) -> None:
        self._attrs.pop(name, None)

    def attribute_names(self) -> list[str]:
        return list(self._attrs.keys())


class _MemoryRoot:
    """Shared root backing a MemoryProvider URL."""

    __slots__ = ("root",)

    def __init__(self) -> None:
        self.root = _Group("/")


class MemoryProvider(StorageProvider):
    """In-memory provider. URLs look like ``memory://<name>``; the
    same name opened twice returns the same tree until
    :meth:`discard_store` wipes it or the process exits.

    API status: Stable (Provisional per M39 — may change before v1.0).

    Cross-language equivalents:
      Objective-C: ``MPGOMemoryProvider``
      Java:        ``com.dtwthalion.mpgo.providers.MemoryProvider``
    """

    def __init__(self, url: str | None = None, root: _MemoryRoot | None = None):
        self._url = url
        self._root = root
        self._open = root is not None

    def open(self_or_path, path_or_url=None, *, mode: str = "r",  # type: ignore[override]
             **kwargs) -> "MemoryProvider":
        """Open a MemoryProvider. Supports both factory
        (``MemoryProvider.open(url, mode="w")``) and instance
        (``p = MemoryProvider(); p.open(url, mode="w")``) styles per
        Appendix B Gap 1."""
        del kwargs
        if isinstance(self_or_path, str):
            actual_path = self_or_path
            instance = MemoryProvider()
        else:
            actual_path = path_or_url
            instance = self_or_path
        if actual_path is None:
            raise TypeError("open() requires a path or URL")

        url = _normalise_url(actual_path)
        if mode == "w":
            _STORES[url] = _MemoryRoot()
        elif mode == "r":
            if url not in _STORES:
                raise FileNotFoundError(
                    f"memory store '{url}' not found (create with mode='w')")
        elif mode in ("r+", "a"):
            _STORES.setdefault(url, _MemoryRoot())
        else:
            raise ValueError(f"unknown mode: {mode}")
        instance._url = url
        instance._root = _STORES[url]
        instance._open = True
        return instance

    def provider_name(self) -> str:
        return "memory"

    def root_group(self) -> StorageGroup:
        return self._root.root

    def is_open(self) -> bool:
        return self._open

    def close(self) -> None:
        self._open = False

    @staticmethod
    def discard_store(url: str) -> None:
        """Remove a named store. Mainly useful in tests."""
        _STORES.pop(_normalise_url(url), None)


def _normalise_url(path_or_url: str) -> str:
    if path_or_url.startswith("memory://"):
        return path_or_url
    return f"memory://{path_or_url}"


def _compound_dtype(fields: tuple[CompoundField, ...]) -> np.dtype:
    items: list[tuple[str, Any]] = []
    for f in fields:
        if f.kind == CompoundFieldKind.UINT32:
            items.append((f.name, "<u4"))
        elif f.kind == CompoundFieldKind.INT64:
            items.append((f.name, "<i8"))
        elif f.kind == CompoundFieldKind.FLOAT64:
            items.append((f.name, "<f8"))
        elif f.kind == CompoundFieldKind.VL_STRING:
            items.append((f.name, object))
        else:
            raise ValueError(f"unknown compound kind: {f.kind}")
    return np.dtype(items)
