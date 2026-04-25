"""Zarr storage provider — Milestone 46 (Track A, stretch).

Validates that the v0.7 storage-provider abstraction
(M43/M44/M45 refinements) generalises beyond HDF5. Zarr is the most
mature alternative chunked-array container with a first-class Python
binding. Backed by zarr-python 3.x — on-disk format is **Zarr v3**
(migrated from v2 in v0.9; pre-deployment, no shim was needed).

URL schemes
-----------
* ``zarr:///path/to/store.zarr`` — directory store on the local
  filesystem (delegates to :class:`zarr.storage.LocalStore`).
* ``zarr+memory://<name>`` — in-memory store, keyed by ``<name>`` so
  two opens of the same URL share state (mirrors
  :class:`~ttio.providers.memory.MemoryProvider`).
* ``zarr+s3://bucket/key`` — cloud-backed store via fsspec
  (delegates to :class:`zarr.storage.FsspecStore`).

Bare paths like ``/tmp/foo.zarr`` map to ``zarr:///tmp/foo.zarr``.

Compound datasets
-----------------
Zarr has no native compound type. This provider stores compound
datasets as plain sub-groups with:

* ``@_ttio_kind = "compound"``
* ``@_ttio_schema = <JSON-list-of-{name, kind}>``
* ``@_ttio_rows = <JSON-list-of-row-dicts>``

This matches the SqliteProvider layout — row-of-dicts preserved in
JSON, no need to wrestle zarr's structured-dtype VL-string quirks.
Primitive N-D datasets use real zarr arrays.

Non-deliverables
----------------
- Java and ObjC ZarrProviders: deferred to v0.8 — Python first to
  stress-test the abstraction.
- Provenance signing / encryption: ZarrProvider is a raw storage
  layer; security plumbing remains HDF5-only in v0.7 (binding
  decision from HANDOFF.md v0.6 §Gotchas).

API status
----------
Provisional (v0.7 M46 stretch). The public surface is the
StorageProvider / StorageGroup / StorageDataset contract; internal
layout conventions may evolve in v0.8 once Java + ObjC catch up.

Cross-language equivalents
--------------------------
Java: deferred to v0.8. Objective-C: deferred to v0.8.

SPDX-License-Identifier: LGPL-3.0-or-later
"""
from __future__ import annotations

import json
import threading
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


try:
    import zarr  # type: ignore[import-not-found]
except ImportError as e:  # pragma: no cover — exercised in tests via skip
    raise ImportError(
        "ttio.providers.zarr requires the optional 'zarr' dependency. "
        "Install with `pip install 'ttio[zarr]'` or `pip install zarr`."
    ) from e


# ── Module-level memory-store registry (mirrors MemoryProvider) ────────

_MEM_STORES: dict[str, Any] = {}
_MEM_LOCK = threading.Lock()


# ── Compound-layout helpers ────────────────────────────────────────────

_COMPOUND_KIND_ATTR = "_ttio_kind"
_COMPOUND_KIND_VALUE = "compound"
_COMPOUND_SCHEMA_ATTR = "_ttio_schema"
_COMPOUND_ROWS_ATTR = "_ttio_rows"
_COMPOUND_COUNT_ATTR = "_ttio_count"
_ND_SHAPE_ATTR = "_ttio_nd_shape"  # preserved for parity; zarr knows shape


def _schema_to_json(fields: list[CompoundField]) -> str:
    return json.dumps([{"name": f.name, "kind": f.kind.value} for f in fields])


def _schema_from_json(blob: str) -> tuple[CompoundField, ...]:
    return tuple(
        CompoundField(name=entry["name"], kind=CompoundFieldKind(entry["kind"]))
        for entry in json.loads(blob)
    )


def _rows_to_json(rows: list[dict[str, Any]],
                   fields: tuple[CompoundField, ...]) -> str:
    """Serialise compound rows with type-aware coercion. Matches the
    shape ``SqliteProvider`` persists so cross-backend canonical-bytes
    parity holds for compound datasets too (M43)."""
    coerced: list[dict[str, Any]] = []
    for row in rows:
        out: dict[str, Any] = {}
        for f in fields:
            v = row.get(f.name)
            if f.kind == CompoundFieldKind.VL_STRING:
                if v is None:
                    out[f.name] = ""
                elif isinstance(v, (bytes, bytearray)):
                    out[f.name] = bytes(v).decode("utf-8", errors="replace")
                else:
                    out[f.name] = str(v)
            elif f.kind == CompoundFieldKind.FLOAT64:
                out[f.name] = float(v) if v is not None else 0.0
            elif f.kind in (CompoundFieldKind.INT64, CompoundFieldKind.UINT32):
                out[f.name] = int(v) if v is not None else 0
            elif f.kind == CompoundFieldKind.VL_BYTES:
                # v1.0 parity gap: Zarr compound is JSON-backed, so
                # VL_BYTES needs base64 transport. Not yet wired;
                # fail loud rather than silently corrupt on write.
                raise NotImplementedError(
                    "ZarrProvider does not yet support VL_BYTES compound "
                    "fields (required for per-AU encryption). Use HDF5 "
                    "or Memory providers for encrypted datasets until "
                    "this lands."
                )
            else:
                out[f.name] = v
        coerced.append(out)
    return json.dumps(coerced)


def _rows_from_json(blob: str) -> list[dict[str, Any]]:
    return list(json.loads(blob))


# ── Dataset wrappers ───────────────────────────────────────────────────


class _ZarrPrimitiveDataset(StorageDataset):
    """Thin wrapper around ``zarr.core.Array`` for primitive datasets.

    Reads go through a lazy numpy materialization cache: the first
    ``read()`` pulls the full decompressed array into a numpy buffer
    (triggering one chunk-decode pass) and subsequent reads slice that
    buffer. This matches the effective behaviour of h5py's chunk cache
    and avoids the asyncio + gzip round-trip that zarr-python 3.x pays
    per-call. Writes invalidate the cache.
    """

    __slots__ = ("_name", "_array", "_parent", "_materialized")

    def __init__(self, name: str, array: Any, parent: Any):
        self._name = name
        self._array = array
        self._parent = parent  # zarr.Group; kept for attribute writes
        self._materialized: np.ndarray | None = None

    @property
    def name(self) -> str:
        return self._name

    @property
    def precision(self) -> Precision | None:
        return _dtype_to_precision(self._array.dtype)

    @property
    def shape(self) -> tuple[int, ...]:
        return tuple(self._array.shape)

    @property
    def chunks(self) -> tuple[int, ...] | None:
        return tuple(self._array.chunks) if self._array.chunks else None

    @property
    def compound_fields(self) -> tuple[CompoundField, ...] | None:
        return None

    def read(self, offset: int = 0, count: int = -1) -> np.ndarray:
        if self._materialized is None:
            # One async round-trip + decode for the whole array; future
            # reads are pure numpy slices.
            self._materialized = np.asarray(self._array[:])
        end = self._materialized.shape[0] if count < 0 else offset + count
        return self._materialized[offset:end]

    def write(self, data: Any) -> None:
        arr = np.asarray(data)
        # zarr-python refuses dtype mismatches; coerce to the array's dtype.
        if arr.dtype != self._array.dtype:
            arr = arr.astype(self._array.dtype)
        if arr.shape == self._array.shape:
            self._array[:] = arr
        else:
            # Caller may pass a flat buffer for an N-D array (mirrors
            # the Hdf5Provider flatten-and-reshape behaviour).
            try:
                arr = arr.reshape(self._array.shape)
            except ValueError as e:
                raise ValueError(
                    f"dataset '{self._name}' expects shape "
                    f"{self._array.shape}, got {arr.shape}") from e
            self._array[:] = arr
        self._materialized = None  # invalidate after write

    def has_attribute(self, name: str) -> bool:
        return name in self._array.attrs

    def get_attribute(self, name: str) -> Any:
        return self._array.attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        self._array.attrs[name] = _coerce_attr_for_json(value)

    def delete_attribute(self, name: str) -> None:
        if name in self._array.attrs:
            del self._array.attrs[name]

    def attribute_names(self) -> list[str]:
        return list(self._array.attrs.keys())


class _ZarrCompoundDataset(StorageDataset):
    """Compound dataset: backed by a zarr sub-group carrying the
    schema + rows as JSON attributes."""

    __slots__ = ("_name", "_group", "_fields", "_count")

    def __init__(self, name: str, group: Any,
                 fields: tuple[CompoundField, ...], count: int):
        self._name = name
        self._group = group
        self._fields = fields
        self._count = count

    @property
    def name(self) -> str:
        return self._name

    @property
    def precision(self) -> Precision | None:
        return None

    @property
    def shape(self) -> tuple[int, ...]:
        return (self._count,)

    @property
    def compound_fields(self) -> tuple[CompoundField, ...] | None:
        return self._fields

    def read(self, offset: int = 0, count: int = -1) -> list[dict[str, Any]]:
        blob = self._group.attrs.get(_COMPOUND_ROWS_ATTR, "[]")
        rows = _rows_from_json(blob)
        end = len(rows) if count < 0 else offset + count
        return rows[offset:end]

    def write(self, data: Any) -> None:
        if isinstance(data, np.ndarray) and data.dtype.names is not None:
            rows = [
                {name: _jsonable(row[name]) for name in data.dtype.names}
                for row in data
            ]
        elif isinstance(data, list):
            rows = [dict(r) for r in data]
        else:
            raise TypeError(
                f"compound dataset '{self._name}' write() expects a "
                f"structured ndarray or list[dict], got {type(data)!r}")
        self._group.attrs[_COMPOUND_ROWS_ATTR] = _rows_to_json(rows, self._fields)
        self._group.attrs[_COMPOUND_COUNT_ATTR] = len(rows)
        self._count = len(rows)

    def has_attribute(self, name: str) -> bool:
        return name in self._group.attrs and not name.startswith("_ttio_")

    def get_attribute(self, name: str) -> Any:
        return self._group.attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        self._group.attrs[name] = _coerce_attr_for_json(value)

    def delete_attribute(self, name: str) -> None:
        if name in self._group.attrs:
            del self._group.attrs[name]

    def attribute_names(self) -> list[str]:
        return [k for k in self._group.attrs.keys() if not k.startswith("_ttio_")]


# ── Group wrapper ──────────────────────────────────────────────────────


class _ZarrGroup(StorageGroup):
    __slots__ = ("_name", "_group")

    def __init__(self, name: str, group: Any):
        self._name = name
        self._group = group

    @property
    def name(self) -> str:
        return self._name

    def child_names(self) -> list[str]:
        # Skip groups that are compound-dataset wrappers — they are
        # reported by open_dataset, not as children.
        names: list[str] = []
        for entry in self._group:
            child = self._group[entry]
            if isinstance(child, zarr.Group):
                if child.attrs.get(_COMPOUND_KIND_ATTR) == _COMPOUND_KIND_VALUE:
                    names.append(entry)  # compound-as-dataset
                else:
                    names.append(entry)  # plain subgroup
            else:
                names.append(entry)  # array
        return names

    def has_child(self, name: str) -> bool:
        return name in self._group

    def open_group(self, name: str) -> StorageGroup:
        if name not in self._group:
            raise KeyError(f"group '{name}' not found in '{self._name}'")
        child = self._group[name]
        if not isinstance(child, zarr.Group):
            raise KeyError(f"'{name}' is a dataset, not a group")
        if child.attrs.get(_COMPOUND_KIND_ATTR) == _COMPOUND_KIND_VALUE:
            raise KeyError(
                f"'{name}' is a compound dataset; use open_dataset()")
        return _ZarrGroup(name, child)

    def create_group(self, name: str) -> StorageGroup:
        if name in self._group:
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        g = self._group.create_group(name)
        return _ZarrGroup(name, g)

    def delete_child(self, name: str) -> None:
        if name in self._group:
            del self._group[name]

    # ── Datasets ──

    def open_dataset(self, name: str) -> StorageDataset:
        if name not in self._group:
            raise KeyError(f"dataset '{name}' not found in '{self._name}'")
        child = self._group[name]
        if isinstance(child, zarr.Group):
            if child.attrs.get(_COMPOUND_KIND_ATTR) != _COMPOUND_KIND_VALUE:
                raise KeyError(f"'{name}' is a group, not a dataset")
            fields = _schema_from_json(child.attrs[_COMPOUND_SCHEMA_ATTR])
            count = int(child.attrs.get(_COMPOUND_COUNT_ATTR, 0))
            return _ZarrCompoundDataset(name, child, fields, count)
        return _ZarrPrimitiveDataset(name, child, self._group)

    def create_dataset(self, name: str, precision: Precision,
                       length: int, *,
                       chunk_size: int = 0,
                       compression: Compression = Compression.NONE,
                       compression_level: int = 6) -> StorageDataset:
        if name in self._group:
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        actual_chunks = (chunk_size,) if chunk_size > 0 else (length,)
        arr = self._group.create_array(
            name=name,
            shape=(length,),
            chunks=actual_chunks,
            dtype=precision.numpy_dtype(),
            compressors=_compressors_for(compression, compression_level),
            overwrite=False,
        )
        return _ZarrPrimitiveDataset(name, arr, self._group)

    def create_dataset_nd(self, name: str, precision: Precision,
                           shape: tuple[int, ...], *,
                           chunks: tuple[int, ...] | None = None,
                           compression: Compression = Compression.NONE,
                           compression_level: int = 6) -> StorageDataset:
        if name in self._group:
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        actual_chunks = tuple(chunks) if chunks else tuple(shape)
        arr = self._group.create_array(
            name=name,
            shape=tuple(shape),
            chunks=actual_chunks,
            dtype=precision.numpy_dtype(),
            compressors=_compressors_for(compression, compression_level),
            overwrite=False,
        )
        return _ZarrPrimitiveDataset(name, arr, self._group)

    def create_compound_dataset(self, name: str,
                                 fields: list[CompoundField],
                                 count: int) -> StorageDataset:
        if name in self._group:
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        g = self._group.create_group(name)
        g.attrs[_COMPOUND_KIND_ATTR] = _COMPOUND_KIND_VALUE
        g.attrs[_COMPOUND_SCHEMA_ATTR] = _schema_to_json(list(fields))
        g.attrs[_COMPOUND_COUNT_ATTR] = count
        g.attrs[_COMPOUND_ROWS_ATTR] = "[]"
        return _ZarrCompoundDataset(name, g, tuple(fields), count)

    # ── Attributes ──

    def has_attribute(self, name: str) -> bool:
        return name in self._group.attrs and not name.startswith("_ttio_")

    def get_attribute(self, name: str) -> Any:
        return self._group.attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        self._group.attrs[name] = _coerce_attr_for_json(value)

    def delete_attribute(self, name: str) -> None:
        if name in self._group.attrs:
            del self._group.attrs[name]

    def attribute_names(self) -> list[str]:
        return [k for k in self._group.attrs.keys() if not k.startswith("_ttio_")]


# ── Provider ───────────────────────────────────────────────────────────


class ZarrProvider(StorageProvider):
    """Zarr-backed storage provider. Accepts ``zarr://``, ``zarr+s3://``,
    ``zarr+memory://`` URL schemes, plus bare filesystem paths.

    See the module docstring for the compound-layout convention and
    scheme details."""

    def __init__(self, url: str | None = None):
        self._url = url
        self._root: Any | None = None
        self._store: Any | None = None
        self._mode: str = "r"
        self._open = False

    def open(self_or_path, path_or_url=None, *, mode: str = "r",  # type: ignore[override]
             **kwargs) -> "ZarrProvider":
        """Dual-style open() per Appendix B Gap 1 — mirrors HDF5 /
        Memory / SQLite providers."""
        del kwargs
        if isinstance(self_or_path, str):
            actual = self_or_path
            instance = ZarrProvider()
        else:
            actual = path_or_url
            instance = self_or_path
        if actual is None:
            raise TypeError("open() requires a path or URL")
        store = _store_for_url(actual, mode)
        # zarr-python's mode strings: 'r', 'r+', 'a', 'w', 'w-'
        zmode = mode if mode in ("r", "r+", "a", "w", "w-") else "r"
        # Never auto-use consolidated metadata: cross-language tests
        # modify files after Python consolidates them (e.g. Java adds
        # a signature attr), and stale consolidated metadata hides
        # those changes. Consolidation remains available to callers
        # via ``native_handle()`` if they know the file is final.
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            root = zarr.open_group(
                store=store, mode=zmode, use_consolidated=False)
        instance._root = root
        instance._store = store
        instance._mode = zmode
        instance._url = actual
        instance._open = True
        return instance

    def provider_name(self) -> str:
        return "zarr"

    def root_group(self) -> StorageGroup:
        if self._root is None:
            raise RuntimeError("ZarrProvider: open() not called")
        return _ZarrGroup("/", self._root)

    def is_open(self) -> bool:
        return self._open

    def close(self) -> None:
        self._open = False
        self._root = None
        self._store = None

    def supports_chunking(self) -> bool:
        return True

    def supports_compression(self) -> bool:
        return True

    def native_handle(self) -> Any:
        """The underlying :class:`zarr.Group` — callers that
        need zarr-specific APIs (consolidate_metadata, tree display)
        can reach for it."""
        return self._root

    @staticmethod
    def discard_memory_store(url: str) -> None:
        """Wipe a ``zarr+memory://`` store. Mainly for tests."""
        with _MEM_LOCK:
            _MEM_STORES.pop(_normalise_memory_url(url), None)


# ── URL → store dispatch ───────────────────────────────────────────────


def _normalise_memory_url(url: str) -> str:
    if url.startswith("zarr+memory://"):
        return url
    if url.startswith("memory://"):
        return "zarr+" + url
    return f"zarr+memory://{url}"


def _store_for_url(url: str, mode: str) -> Any:
    """Dispatch a URL to a concrete zarr store. Mode is advisory for
    memory-backed stores (they always retain prior state unless mode
    == 'w').

    v1.0: targets zarr-python 3.x, which renamed the stores:
      DirectoryStore -> LocalStore
      FSStore        -> FsspecStore
    The `zarr+memory://` convention still maps to MemoryStore.
    """
    if url.startswith("zarr+memory://"):
        key = _normalise_memory_url(url)
        with _MEM_LOCK:
            if mode == "w":
                _MEM_STORES[key] = zarr.storage.MemoryStore()
            return _MEM_STORES.setdefault(key, zarr.storage.MemoryStore())
    if url.startswith("zarr+s3://"):
        remainder = url[len("zarr+s3://"):]
        # Relies on s3fs being installed; surfacing ImportError is fine.
        return zarr.storage.FsspecStore.from_url(f"s3://{remainder}")
    if url.startswith("zarr://"):
        path = url[len("zarr://"):]
        # Triple-slash → absolute path: strip leading '//' that parse
        # artefacts may leave in.
        if path.startswith("//"):
            path = path[2:]
        return zarr.storage.LocalStore(path)
    # Bare path: assume local directory.
    return zarr.storage.LocalStore(url)


# ── Dtype ↔ Precision mapping ─────────────────────────────────────────

_DTYPE_TO_PRECISION: dict[str, Precision] = {
    "float64": Precision.FLOAT64,
    "float32": Precision.FLOAT32,
    "int64": Precision.INT64,
    "int32": Precision.INT32,
    "uint32": Precision.UINT32,
    "uint8": Precision.UINT8,
}


def _dtype_to_precision(dtype: np.dtype) -> Precision | None:
    return _DTYPE_TO_PRECISION.get(dtype.name)


def _compressors_for(compression: Compression, level: int) -> tuple | None:
    """Map the TTI-O compression enum onto a zarr v3 codec chain.

    Returns a tuple suitable for ``create_array(compressors=...)`` in
    zarr-python 3.x. ``None`` (not an empty tuple) disables compression
    and makes the chunk-byte pipeline just the ``bytes`` codec.

    v1.0: zarr-python 3 uses its own codec registry rooted in
    :mod:`zarr.codecs`. The cross-language Java + ObjC providers
    (self-contained, no zarr dependency) emit the same on-disk bytes
    by calling the platform zlib/gzip directly, so any codec we pick
    here must be one those readers can decode. ``GzipCodec`` is the
    canonical ZLIB choice — it serialises as ``{"name": "gzip",
    "configuration": {"level": N}}`` in the v3 ``zarr.json``.
    """
    if compression in (Compression.NONE, None):
        return None
    from zarr.codecs import GzipCodec
    if compression == Compression.ZLIB:
        return (GzipCodec(level=max(1, min(level, 9))),)
    if compression == Compression.LZ4:
        # LZ4 is opt-in and the self-contained Java/ObjC readers
        # don't claim LZ4 decode support. Fall back to gzip.
        return (GzipCodec(level=max(1, min(level, 9))),)
    return None


# Legacy name kept for any caller still importing the older helper.
def _compressor_for(compression: Compression, level: int) -> Any:
    codecs = _compressors_for(compression, level)
    return codecs[0] if codecs else None


# ── Attribute coercion (zarr attrs must be JSON-serialisable) ──────────


def _coerce_attr_for_json(value: Any) -> Any:
    """Zarr attrs go through JSON. NumPy scalars aren't serialisable by
    default; coerce to Python types. Bytes round-trip via
    :mod:`base64` is a v0.8 concern — TTI-O attrs are str / int /
    float today."""
    if isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, (bytes, bytearray)):
        try:
            return bytes(value).decode("utf-8")
        except UnicodeDecodeError as e:
            raise ValueError(
                "ZarrProvider cannot store non-UTF-8 byte attributes") from e
    if isinstance(value, (list, tuple)):
        return [_coerce_attr_for_json(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _coerce_attr_for_json(v) for k, v in value.items()}
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, np.ndarray):
        return value.tolist()
    return value


def _jsonable(v: Any) -> Any:
    if isinstance(v, np.generic):
        return v.item()
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).decode("utf-8", errors="replace")
    return v


__all__ = ["ZarrProvider"]
