"""HDF5 storage provider — Milestone 39 Part C.

Adapter that exposes ``h5py`` through the :mod:`mpeg_o.providers.base`
contract. No behavioural change — callers that used ``h5py.File``
directly can switch to ``Hdf5Provider.open(path)`` and continue.

API status: Stable (Provisional per M39 — may change before v1.0).

Cross-language equivalents
--------------------------
Objective-C: ``MPGOHDF5Provider`` class
Java:        ``com.dtwthalion.mpgo.providers.Hdf5Provider`` class

SPDX-License-Identifier: LGPL-3.0-or-later
"""
from __future__ import annotations

from typing import Any

import h5py
import numpy as np

from ..enums import Compression, Precision
from .base import (
    CompoundField,
    CompoundFieldKind,
    StorageDataset,
    StorageGroup,
    StorageProvider,
)


# ── Precision / dtype glue ────────────────────────────────────────────


def _precision_from_dtype(dt: np.dtype) -> Precision | None:
    """Map an h5py dataset dtype to the MPEG-O Precision enum, or
    ``None`` for compound datasets."""
    if dt.kind == "V":  # void — compound or opaque
        return None
    by_dtype = {
        "<f4": Precision.FLOAT32, "<f8": Precision.FLOAT64,
        "<i4": Precision.INT32, "<i8": Precision.INT64,
        "<u4": Precision.UINT32, "<c16": Precision.COMPLEX128,
    }
    return by_dtype.get(dt.str)


def _fields_from_dtype(dt: np.dtype) -> tuple[CompoundField, ...] | None:
    if dt.names is None:
        return None
    out: list[CompoundField] = []
    for nm in dt.names:
        sub = dt.fields[nm][0]
        if h5py.check_string_dtype(sub) is not None:
            kind = CompoundFieldKind.VL_STRING
        elif sub.str == "<u4":
            kind = CompoundFieldKind.UINT32
        elif sub.str == "<i8":
            kind = CompoundFieldKind.INT64
        elif sub.str == "<f8":
            kind = CompoundFieldKind.FLOAT64
        else:
            # Unknown field kind — leave as float64 placeholder; callers
            # that care should downgrade gracefully.
            kind = CompoundFieldKind.FLOAT64
        out.append(CompoundField(name=nm, kind=kind))
    return tuple(out)


def _compound_dtype(fields: list[CompoundField]) -> np.dtype:
    items: list[tuple[str, Any]] = []
    vl_str = h5py.string_dtype(encoding="utf-8")
    vl_bytes = h5py.vlen_dtype(np.uint8)
    for f in fields:
        if f.kind == CompoundFieldKind.UINT32:
            items.append((f.name, "<u4"))
        elif f.kind == CompoundFieldKind.INT64:
            items.append((f.name, "<i8"))
        elif f.kind == CompoundFieldKind.FLOAT64:
            items.append((f.name, "<f8"))
        elif f.kind == CompoundFieldKind.VL_STRING:
            items.append((f.name, vl_str))
        elif f.kind == CompoundFieldKind.VL_BYTES:
            items.append((f.name, vl_bytes))
        else:
            raise ValueError(f"unknown compound kind: {f.kind}")
    return np.dtype(items)


# ── Adapters ──────────────────────────────────────────────────────────


class _Dataset(StorageDataset):
    def __init__(self, ds: h5py.Dataset):
        self._ds = ds

    @property
    def name(self) -> str:
        return self._ds.name.rsplit("/", 1)[-1]

    @property
    def precision(self) -> Precision | None:
        return _precision_from_dtype(self._ds.dtype)

    @property
    def shape(self) -> tuple[int, ...]:
        return tuple(self._ds.shape) if self._ds.shape else (0,)

    @property
    def chunks(self) -> tuple[int, ...] | None:
        c = self._ds.chunks
        return tuple(c) if c else None

    @property
    def compound_fields(self) -> tuple[CompoundField, ...] | None:
        return _fields_from_dtype(self._ds.dtype)

    def read(self, offset: int = 0, count: int = -1) -> np.ndarray:
        if count < 0:
            return self._ds[offset:]
        return self._ds[offset: offset + count]

    def write(self, data: np.ndarray | list) -> None:
        # StorageDataset contract: primitive datasets take array-like;
        # compound datasets take a list of dicts. The latter was
        # previously handled only on Memory + SQLite + Zarr; HDF5
        # needed list-of-dicts support too so the per-AU encryption
        # writer could round-trip through the provider abstraction.
        if (self._ds.dtype.fields is not None
                and isinstance(data, list)):
            dt = self._ds.dtype
            arr = np.zeros(len(data), dtype=dt)
            for i, rec in enumerate(data):
                for fname in dt.fields:
                    if fname in rec:
                        val = rec[fname]
                        subdt = dt.fields[fname][0]
                        if subdt == h5py.vlen_dtype(np.uint8):
                            arr[i][fname] = np.frombuffer(
                                bytes(val), dtype=np.uint8
                            )
                        else:
                            arr[i][fname] = val
            self._ds[...] = arr
            return
        self._ds[...] = data

    def has_attribute(self, name: str) -> bool:
        return name in self._ds.attrs

    def get_attribute(self, name: str) -> Any:
        return self._ds.attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        self._ds.attrs[name] = value

    def delete_attribute(self, name: str) -> None:
        if name in self._ds.attrs:
            del self._ds.attrs[name]

    def attribute_names(self) -> list[str]:
        return list(self._ds.attrs.keys())


class _Group(StorageGroup):
    def __init__(self, grp: h5py.Group):
        self._grp = grp

    @property
    def name(self) -> str:
        return self._grp.name.rsplit("/", 1)[-1] or "/"

    def child_names(self) -> list[str]:
        return list(self._grp.keys())

    def has_child(self, name: str) -> bool:
        return name in self._grp

    def open_group(self, name: str) -> StorageGroup:
        obj = self._grp[name]
        if not isinstance(obj, h5py.Group):
            raise KeyError(f"'{name}' is not a group")
        return _Group(obj)

    def create_group(self, name: str) -> StorageGroup:
        return _Group(self._grp.create_group(name))

    def delete_child(self, name: str) -> None:
        if name in self._grp:
            del self._grp[name]

    def open_dataset(self, name: str) -> StorageDataset:
        obj = self._grp[name]
        if not isinstance(obj, h5py.Dataset):
            raise KeyError(f"'{name}' is not a dataset")
        return _Dataset(obj)

    def create_dataset(self, name: str, precision: Precision,
                       length: int, *,
                       chunk_size: int = 0,
                       compression: Compression = Compression.NONE,
                       compression_level: int = 6) -> StorageDataset:
        kwargs: dict[str, Any] = {
            "shape": (length,),
            "dtype": precision.numpy_dtype(),
        }
        if chunk_size > 0:
            kwargs["chunks"] = (min(chunk_size, max(length, 1)),)
        if compression == Compression.ZLIB:
            kwargs["compression"] = "gzip"
            kwargs["compression_opts"] = compression_level
        elif compression == Compression.LZ4:
            # LZ4 filter id 32004; requires hdf5plugin on the read side.
            kwargs["compression"] = 32004
        ds = self._grp.create_dataset(name, **kwargs)
        return _Dataset(ds)

    def create_dataset_nd(self, name: str, precision: Precision,
                           shape: tuple[int, ...], *,
                           chunks: tuple[int, ...] | None = None,
                           compression: Compression = Compression.NONE,
                           compression_level: int = 6) -> StorageDataset:
        kwargs: dict[str, Any] = {
            "shape": shape,
            "dtype": precision.numpy_dtype(),
        }
        if chunks is not None:
            kwargs["chunks"] = tuple(chunks)
        if compression == Compression.ZLIB:
            kwargs["compression"] = "gzip"
            kwargs["compression_opts"] = compression_level
        elif compression == Compression.LZ4:
            kwargs["compression"] = 32004
        ds = self._grp.create_dataset(name, **kwargs)
        return _Dataset(ds)

    def create_compound_dataset(self, name: str,
                                 fields: list[CompoundField],
                                 count: int) -> StorageDataset:
        dt = _compound_dtype(fields)
        ds = self._grp.create_dataset(name, shape=(count,), dtype=dt)
        return _Dataset(ds)

    def has_attribute(self, name: str) -> bool:
        return name in self._grp.attrs

    def get_attribute(self, name: str) -> Any:
        return self._grp.attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        self._grp.attrs[name] = value

    def delete_attribute(self, name: str) -> None:
        if name in self._grp.attrs:
            del self._grp.attrs[name]

    def attribute_names(self) -> list[str]:
        return list(self._grp.attrs.keys())


class Hdf5Provider(StorageProvider):
    """Storage provider backed by an h5py-managed HDF5 file.

    API status: Stable (Provisional per M39 — may change before v1.0).

    Cross-language equivalents:
      Objective-C: ``MPGOHDF5Provider``
      Java:        ``com.dtwthalion.mpgo.providers.Hdf5Provider``
    """

    def __init__(self, file: h5py.File | None = None):
        self._file = file

    def open(self_or_path, path_or_url=None, *, mode: str = "r",  # type: ignore[override]
             **kwargs) -> "Hdf5Provider":
        """Open an HDF5 file under this provider. Supports both factory
        and instance call styles per Appendix B Gap 1 — see
        :class:`mpeg_o.providers.base.StorageProvider.open`."""
        # Dispatch: classmethod call passes the class as first arg;
        # instance call passes self. Detect by whether first arg is
        # a string (= path) or a provider instance.
        if isinstance(self_or_path, str):
            # Factory style: Hdf5Provider.open("/path", mode="w")
            actual_path = self_or_path
            instance = Hdf5Provider()
        else:
            # Instance style: p = Hdf5Provider(); p.open("/path", mode="w")
            actual_path = path_or_url
            instance = self_or_path
        if actual_path is None:
            raise TypeError("open() requires a path or URL")

        # Accept fsspec URLs too: h5py can take a file-like object from
        # fsspec. That makes Hdf5Provider usable over S3/HTTP transports
        # without any extra wiring.
        if "://" in actual_path and not actual_path.startswith("file://"):
            try:
                import fsspec  # type: ignore[import-not-found]
            except ImportError as e:  # pragma: no cover
                raise ImportError(
                    "Opening HDF5 over a URL scheme requires fsspec "
                    "(pip install 'mpeg-o[cloud]')") from e
            f = fsspec.open(actual_path, mode="rb" if mode == "r" else mode).open()
            instance._file = h5py.File(f, mode=mode, **kwargs)
            return instance
        if actual_path.startswith("file://"):
            actual_path = actual_path[len("file://"):]
        instance._file = h5py.File(actual_path, mode=mode, **kwargs)
        return instance

    def provider_name(self) -> str:
        return "hdf5"

    def root_group(self) -> StorageGroup:
        return _Group(self._file)

    def is_open(self) -> bool:
        return bool(self._file)

    def close(self) -> None:
        try:
            self._file.close()
        except Exception:
            pass

    def supports_chunking(self) -> bool:
        return True

    def supports_compression(self) -> bool:
        return True

    def native_handle(self) -> h5py.File:
        """Underlying h5py.File — escape hatch for byte-level code
        (signature hashing, encryption, native compression filters)."""
        return self._file
