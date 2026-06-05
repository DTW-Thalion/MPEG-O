"""HDF5 storage provider — Part C.

Adapter that exposes ``h5py`` through the :mod:`ttio.providers.base`
contract. No behavioural change — callers that used ``h5py.File``
directly can switch to ``Hdf5Provider.open(path)`` and continue.

API status: Stable (Provisional per M39 — may change before v1.0).

Cross-language equivalents
--------------------------
Objective-C: ``TTIOHDF5Provider`` class
Java:        ``global.thalion.ttio.providers.Hdf5Provider`` class

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
    """Map an h5py dataset dtype to the TTI-O Precision enum, or
    ``None`` for compound datasets."""
    if dt.kind == "V":  # void — compound or opaque
        return None
    by_dtype = {
        "<f4": Precision.FLOAT32, "<f8": Precision.FLOAT64,
        "<i4": Precision.INT32, "<i8": Precision.INT64,
        "<u4": Precision.UINT32, "<c16": Precision.COMPLEX128,
        "|u1": Precision.UINT8,
        "<u2": Precision.UINT16,
        "<u8": Precision.UINT64,
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
        """Wrap an :class:`h5py.Dataset` as a :class:`StorageDataset`.

        Parameters
        ----------
        ds : h5py.Dataset
            The h5py-managed dataset to adapt. The wrapper holds a
            borrowed reference; lifetime is owned by the enclosing
            :class:`Hdf5Provider`.
        """
        self._ds = ds

    @property
    def name(self) -> str:
        """Leaf name of the dataset within its parent group.

        The full HDF5 path's trailing component (after the final
        ``/``). For example, an h5py dataset at
        ``/study/spectra/intensities`` returns ``"intensities"``.
        """
        return self._ds.name.rsplit("/", 1)[-1]

    @property
    def precision(self) -> Precision | None:
        """The TTI-O :class:`Precision` enum describing the element type.

        Returns
        -------
        Precision or None
            The matching enum value for primitive dtypes; ``None``
            when the dataset is a compound (void) record array, in
            which case :attr:`compound_fields` describes the schema.
        """
        return _precision_from_dtype(self._ds.dtype)

    @property
    def shape(self) -> tuple[int, ...]:
        """Dataset shape as a tuple of dimension lengths.

        Scalar datasets (h5py shape ``()``) are reported as ``(0,)``
        for parity with the other providers' length-based API.
        """
        return tuple(self._ds.shape) if self._ds.shape else (0,)

    @property
    def chunks(self) -> tuple[int, ...] | None:
        """Chunk shape tuple, or ``None`` if the dataset is contiguous."""
        c = self._ds.chunks
        return tuple(c) if c else None

    @property
    def compound_fields(self) -> tuple[CompoundField, ...] | None:
        """Field schema for a compound dataset, or ``None`` for primitives.

        Returns
        -------
        tuple of CompoundField or None
            One :class:`CompoundField` per named field in the
            underlying compound dtype, in declaration order. Returns
            ``None`` when the dataset is a primitive array (and
            :attr:`precision` is then non-``None``).
        """
        return _fields_from_dtype(self._ds.dtype)

    def read(self, offset: int = 0, count: int = -1) -> np.ndarray:
        """Read a contiguous slice of the dataset into a NumPy array.

        Parameters
        ----------
        offset : int, optional
            Starting element index (default ``0``).
        count : int, optional
            Number of elements to read. ``-1`` (default) reads from
            ``offset`` to the end of the dataset.

        Returns
        -------
        numpy.ndarray
            The slice ``[offset, offset+count)`` (or ``[offset, end)``
            when ``count < 0``). For compound datasets the result is
            a structured array; for primitives, an array of the
            dataset's dtype.
        """
        if count < 0:
            return self._ds[offset:]
        return self._ds[offset: offset + count]

    def write(self, data: np.ndarray | list) -> None:
        """Overwrite the dataset's contents.

        Primitive datasets accept any array-like the underlying
        h5py dataset can ingest; compound datasets accept either a
        structured ``numpy.ndarray`` or a list of dicts (one per
        record). For compound writes, fields named in the dicts are
        copied; missing fields stay at their dtype default. ``bytes``
        values for variable-length byte fields are coerced to
        ``uint8`` arrays.

        Parameters
        ----------
        data : numpy.ndarray or list of dict
            Replacement values. The shape must match
            :attr:`shape`.
        """
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
        """Return ``True`` when an attribute with this name exists.

        Parameters
        ----------
        name : str
            HDF5 attribute name to probe.

        Returns
        -------
        bool
        """
        return name in self._ds.attrs

    def get_attribute(self, name: str) -> Any:
        """Return the value of a named attribute.

        Parameters
        ----------
        name : str
            HDF5 attribute name.

        Returns
        -------
        Any
            The attribute value as h5py returns it (scalar, ndarray,
            or bytes/string).

        Raises
        ------
        KeyError
            If no such attribute is set on this dataset.
        """
        return self._ds.attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        """Create or overwrite a named attribute on the dataset.

        Parameters
        ----------
        name : str
            Attribute name.
        value : Any
            Scalar, NumPy array, or string accepted by h5py. The
            value is stored verbatim; type coercion follows h5py
            defaults.
        """
        self._ds.attrs[name] = value

    def delete_attribute(self, name: str) -> None:
        """Remove an attribute from the dataset if present.

        Parameters
        ----------
        name : str
            Attribute name to remove. Missing names are silently
            ignored (idempotent).
        """
        if name in self._ds.attrs:
            del self._ds.attrs[name]

    def attribute_names(self) -> list[str]:
        """Return the list of attribute names defined on this dataset.

        Returns
        -------
        list of str
            Names in iteration order as exposed by h5py.
        """
        return list(self._ds.attrs.keys())


class _Group(StorageGroup):
    def __init__(self, grp: h5py.Group):
        """Wrap an :class:`h5py.Group` as a :class:`StorageGroup`.

        Parameters
        ----------
        grp : h5py.Group
            The h5py-managed group (or root file handle) to adapt.
        """
        self._grp = grp

    @property
    def name(self) -> str:
        """Leaf name of the group within its parent, or ``"/"`` for root."""
        return self._grp.name.rsplit("/", 1)[-1] or "/"

    def child_names(self) -> list[str]:
        """Return the immediate children of this group (groups and datasets).

        Returns
        -------
        list of str
            Names in HDF5 iteration order. Nested children (grand-
            children, etc.) are not included.
        """
        return list(self._grp.keys())

    def has_child(self, name: str) -> bool:
        """Return ``True`` when a child group or dataset of that name exists.

        Parameters
        ----------
        name : str
            Immediate child name (not a slash-separated path).

        Returns
        -------
        bool
        """
        return name in self._grp

    def open_group(self, name: str) -> StorageGroup:
        """Open an existing child as a :class:`StorageGroup`.

        Parameters
        ----------
        name : str
            Immediate child name.

        Returns
        -------
        StorageGroup
            Adapter wrapping the child h5py group.

        Raises
        ------
        KeyError
            If the child does not exist, or if it exists but is a
            dataset rather than a group.
        """
        obj = self._grp[name]
        if not isinstance(obj, h5py.Group):
            raise KeyError(f"'{name}' is not a group")
        return _Group(obj)

    def create_group(self, name: str) -> StorageGroup:
        """Create a new child group and return its adapter.

        Parameters
        ----------
        name : str
            Immediate child name. Must not already exist (h5py
            raises if it does).

        Returns
        -------
        StorageGroup
        """
        return _Group(self._grp.create_group(name))

    def delete_child(self, name: str) -> None:
        """Remove a child group or dataset if present.

        Parameters
        ----------
        name : str
            Immediate child name. Missing names are silently ignored
            (idempotent).
        """
        if name in self._grp:
            del self._grp[name]

    def open_dataset(self, name: str) -> StorageDataset:
        """Open an existing child as a :class:`StorageDataset`.

        Parameters
        ----------
        name : str
            Immediate child name.

        Returns
        -------
        StorageDataset
            Adapter wrapping the child h5py dataset.

        Raises
        ------
        KeyError
            If the child does not exist, or if it exists but is a
            group rather than a dataset.
        """
        obj = self._grp[name]
        if not isinstance(obj, h5py.Dataset):
            raise KeyError(f"'{name}' is not a dataset")
        return _Dataset(obj)

    def create_dataset(self, name: str, precision: Precision,
                       length: int, *,
                       chunk_size: int = 0,
                       compression: Compression = Compression.NONE,
                       compression_level: int = 6) -> StorageDataset:
        """Create a 1-D primitive dataset under this group.

        Parameters
        ----------
        name : str
            Immediate child name. Must not already exist.
        precision : Precision
            Element type for the dataset.
        length : int
            Number of elements to allocate.
        chunk_size : int, optional
            HDF5 chunk size along the single axis. ``0`` (default)
            or a zero-length dataset disables chunking (and
            therefore compression). When non-zero, the chunk is
            clamped to ``min(chunk_size, length)`` so the chunk
            shape never exceeds the dataset shape.
        compression : Compression, optional
            On-disk compression algorithm. ``ZLIB`` maps to HDF5
            gzip; ``LZ4`` registers the LZ4 plugin filter id
            ``32004`` (the reader needs ``hdf5plugin`` installed to
            decompress). ``NONE`` (default) writes uncompressed.
            Compression requires chunking, so it is silently dropped
            when ``chunk_size`` is ``0`` or ``length`` is zero.
        compression_level : int, optional
            ZLIB level forwarded as ``compression_opts``. Default
            ``6``. Ignored for non-ZLIB codecs.

        Returns
        -------
        StorageDataset
            Adapter wrapping the new h5py dataset.
        """
        kwargs: dict[str, Any] = {
            "shape": (length,),
            "dtype": precision.numpy_dtype(),
        }
        if length > 0 and chunk_size > 0:
            # HDF5 requires chunk shape <= dataset shape in every dimension.
            # Skip chunking (and compression, which requires chunking) for
            # zero-length datasets so empty-run writes don't raise ValueError.
            kwargs["chunks"] = (min(chunk_size, length),)
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
        """Create an N-D primitive dataset under this group.

        Used for image cubes and 2-D NMR cubes (and any other
        multi-dimensional payload that doesn't fit the 1-D
        :meth:`create_dataset` shape).

        Parameters
        ----------
        name : str
            Immediate child name. Must not already exist.
        precision : Precision
            Element type for the dataset.
        shape : tuple of int
            Per-dimension lengths.
        chunks : tuple of int, optional
            Per-dimension chunk shape. ``None`` (default) writes
            contiguously (which disables compression).
        compression : Compression, optional
            On-disk compression. ``ZLIB`` maps to gzip; ``LZ4`` uses
            filter id ``32004``; ``NONE`` (default) is uncompressed.
        compression_level : int, optional
            ZLIB level. Default ``6``. Ignored for non-ZLIB codecs.

        Returns
        -------
        StorageDataset
        """
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
        """Create a compound-record dataset under this group.

        Compound datasets carry one record per row, with each field
        having an independent type drawn from
        :class:`CompoundFieldKind`. Used by the per-AU encryption,
        identifications, and quantifications tables.

        Parameters
        ----------
        name : str
            Immediate child name. Must not already exist.
        fields : list of CompoundField
            Field schema in declaration order. Each field's kind is
            mapped to a NumPy dtype: ``UINT32``/``INT64``/``FLOAT64``
            map to little-endian numeric dtypes; ``VL_STRING`` and
            ``VL_BYTES`` map to h5py variable-length string and
            uint8 buffer types.
        count : int
            Number of records (rows) to allocate.

        Returns
        -------
        StorageDataset
            Adapter wrapping the new compound h5py dataset.
        """
        dt = _compound_dtype(fields)
        ds = self._grp.create_dataset(name, shape=(count,), dtype=dt)
        return _Dataset(ds)

    def has_attribute(self, name: str) -> bool:
        """Return ``True`` when an attribute with this name exists on the group."""
        return name in self._grp.attrs

    def get_attribute(self, name: str) -> Any:
        """Return the value of a named attribute on the group.

        Parameters
        ----------
        name : str
            HDF5 attribute name.

        Returns
        -------
        Any
            Attribute value as h5py returns it.

        Raises
        ------
        KeyError
            If no such attribute is set on this group.
        """
        return self._grp.attrs[name]

    def set_attribute(self, name: str, value: Any) -> None:
        """Create or overwrite a named attribute on the group.

        Parameters
        ----------
        name : str
            Attribute name.
        value : Any
            Scalar, NumPy array, or string accepted by h5py.
        """
        self._grp.attrs[name] = value

    def delete_attribute(self, name: str) -> None:
        """Remove an attribute from the group if present.

        Idempotent: missing names are silently ignored.
        """
        if name in self._grp.attrs:
            del self._grp.attrs[name]

    def attribute_names(self) -> list[str]:
        """Return the list of attribute names defined on this group.

        Returns
        -------
        list of str
            Names in iteration order as exposed by h5py.
        """
        return list(self._grp.attrs.keys())


class Hdf5Provider(StorageProvider):
    """Storage provider backed by an h5py-managed HDF5 file.

    API status: Stable (Provisional per M39 — may change before v1.0).

    Cross-language equivalents:
      Objective-C: ``TTIOHDF5Provider``
      Java:        ``global.thalion.ttio.providers.Hdf5Provider``
    """

    def __init__(self, file: h5py.File | None = None):
        """Construct a provider, optionally pre-bound to an open h5py file.

        Parameters
        ----------
        file : h5py.File, optional
            An already-open file handle to adopt. ``None`` (the
            default) creates a closed provider; :meth:`open` must
            then be called before any group/dataset access.
        """
        self._file = file

    def open(self_or_path, path_or_url=None, *, mode: str = "r",  # type: ignore[override]
             **kwargs) -> "Hdf5Provider":
        """Open an HDF5 file (or fsspec URL) and return a bound provider.

        Supports both factory and instance call styles per the
        :class:`ttio.providers.base.StorageProvider.open` contract:
        ``Hdf5Provider.open("/path", mode="w")`` returns a fresh
        provider; ``p = Hdf5Provider(); p.open("/path", mode="w")``
        mutates and returns the same instance.

        ``fsspec`` URL schemes (``s3://``, ``http(s)://``, etc.) are
        opened via the optional ``ttio[cloud]`` dependency; the
        ``file://`` scheme is stripped and the rest of the URL is
        treated as a local path.

        Parameters
        ----------
        path_or_url : str
            Filesystem path or fsspec-compatible URL. In factory
            style this is the first positional argument; in instance
            style it is the second.
        mode : str, optional
            h5py file-open mode (``"r"``, ``"r+"``, ``"w"``,
            ``"w-"``, ``"a"``). Default ``"r"``.
        **kwargs
            Forwarded to :class:`h5py.File`.

        Returns
        -------
        Hdf5Provider
            Bound provider with :attr:`is_open` set to ``True``.

        Raises
        ------
        TypeError
            If no path or URL is supplied.
        ImportError
            If a URL scheme is given but ``fsspec`` is not installed.
        """
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
                    "(pip install 'ttio[cloud]')") from e
            f = fsspec.open(actual_path, mode="rb" if mode == "r" else mode).open()
            instance._file = h5py.File(f, mode=mode, **kwargs)
            return instance
        if actual_path.startswith("file://"):
            actual_path = actual_path[len("file://"):]
        instance._file = h5py.File(actual_path, mode=mode, **kwargs)
        return instance

    @classmethod
    def _from_open_h5py(cls, f: "h5py.File") -> "Hdf5Provider":
        """Wrap an already-open :class:`h5py.File` without reopening it.

        Used for remote fsspec-backed handles already wrapped in an
        ``h5py.File`` by the caller. Mirrors the single instance
        attribute (:attr:`_file`) that :meth:`open` sets.
        """
        instance = cls()
        instance._file = f
        return instance

    def provider_name(self) -> str:
        """Return the provider's stable identifier string (``"hdf5"``)."""
        return "hdf5"

    def root_group(self) -> StorageGroup:
        """Return the file's root group as a :class:`StorageGroup`.

        The root is the top-level container; child groups and
        datasets are reached via :meth:`StorageGroup.open_group` /
        :meth:`StorageGroup.open_dataset`.
        """
        return _Group(self._file)

    def is_open(self) -> bool:
        """Return ``True`` when the provider has an open backing file."""
        return bool(self._file)

    def close(self) -> None:
        """Close the underlying h5py file if open.

        Idempotent: a close error or a second call is silently
        swallowed so the method is safe to call from cleanup paths.
        """
        try:
            self._file.close()
        except Exception:
            pass

    def supports_chunking(self) -> bool:
        """Return ``True`` — HDF5 always supports chunked storage."""
        return True

    def supports_compression(self) -> bool:
        """Return ``True`` — HDF5 supports the documented compression filters."""
        return True

    def native_handle(self) -> h5py.File:
        """Return the underlying :class:`h5py.File` handle.

        .. deprecated::
            ``native_handle()`` is deprecated and slated for removal in a
            future coordinated major. Reach storage through
            :meth:`root_group` and the :class:`StorageGroup` protocol
            instead. (Parity with the Java SDK's
            ``@Deprecated(forRemoval=true)``.)

        Escape hatch for byte-level code (signature hashing,
        encryption, native compression filters) that has to bypass
        the provider abstraction. Callers must not close the handle;
        ownership remains with the provider.

        Returns
        -------
        h5py.File
        """
        import warnings
        warnings.warn(
            "StorageProvider.native_handle() is deprecated and slated for "
            "removal; reach storage through root_group() and the StorageGroup "
            "protocol. (Parity with the Java SDK's @Deprecated(forRemoval=true).)",
            DeprecationWarning,
            stacklevel=2,
        )
        return self._file
