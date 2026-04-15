"""Low-level HDF5 helpers that bridge Python dataclasses to the on-disk
layout defined by ``docs/format-spec.md``.

This module is intentionally private (leading underscore). Nothing inside
should leak beyond the in-package readers and writers; if a helper does
become useful externally it should graduate to a public module.

Cross-compatibility notes
-------------------------

The Objective-C reference implementation writes string attributes as
fixed-length ``H5T_STR_NULLTERM`` strings sized to ``strlen(value)``. When
h5py writes via its low-level API it enforces a real trailing ``\0`` byte,
so we size the Python-written attribute to ``len(value) + 1``. Both layouts
are readable by either side — the ObjC reader always allocates
``size + 1`` and relies on ``stringWithUTF8String:`` to terminate. Exact
byte-for-byte agreement is reserved for the M18 canonical-signature pass.

Variable-length strings inside **compound datasets** use
``h5py.string_dtype()`` (UTF-8 VL), matching what the ObjC side writes via
``H5T_C_S1`` with ``H5T_VARIABLE``.
"""
from __future__ import annotations

import json
from typing import Any, Iterable, Sequence

import h5py
import numpy as np

# ------------------------------------------------------------------ attrs ---


def _as_bytes(value: str) -> bytes:
    """Encode to UTF-8 bytes, empty-string tolerant."""
    return value.encode("utf-8") if value else b""


def write_fixed_string_attr(obj: h5py.HLObject, name: str, value: str) -> None:
    """Write a fixed-length NULLTERM string attribute matching ObjC layout.

    If the attribute already exists it is deleted and recreated, because the
    size of an existing attribute cannot be changed in place.
    """
    data = _as_bytes(value)
    size = len(data) + 1  # reserve the byte h5py insists on for NULLTERM
    tid = h5py.h5t.C_S1.copy()
    tid.set_size(size)
    tid.set_strpad(h5py.h5t.STR_NULLTERM)
    space = h5py.h5s.create(h5py.h5s.SCALAR)
    nbytes = name.encode("utf-8")
    if h5py.h5a.exists(obj.id, nbytes):
        h5py.h5a.delete(obj.id, nbytes)
    aid = h5py.h5a.create(obj.id, nbytes, tid, space)
    padded = data + b"\x00"
    buf = np.frombuffer(padded, dtype="|S%d" % size).copy()
    aid.write(buf)
    aid.close()


def read_string_attr(obj: h5py.HLObject, name: str, default: str | None = None) -> str | None:
    """Read a string attribute, tolerating bytes / numpy scalar forms.

    Returns ``default`` if the attribute is absent.
    """
    if name not in obj.attrs:
        return default
    raw = obj.attrs[name]
    if isinstance(raw, bytes):
        return raw.decode("utf-8")
    if isinstance(raw, np.bytes_):
        return raw.tobytes().decode("utf-8")
    if isinstance(raw, str):
        return raw
    # h5py may return ndarray of strings/bytes for 1-element arrays
    if isinstance(raw, np.ndarray) and raw.size == 1:
        return read_string_attr_from_scalar(raw.item())
    return str(raw)


def read_string_attr_from_scalar(value: Any) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return str(value)


def write_int_attr(obj: h5py.HLObject, name: str, value: int, dtype: str = "<i8") -> None:
    obj.attrs.create(name, np.array(value, dtype=dtype))


def read_int_attr(obj: h5py.HLObject, name: str, default: int | None = None) -> int | None:
    if name not in obj.attrs:
        return default
    return int(obj.attrs[name])


# ------------------------------------------------------ signal channels ---

DEFAULT_SIGNAL_CHUNK = 16384
DEFAULT_INDEX_CHUNK = 1024


def _lz4_filter_kwargs() -> dict[str, Any]:
    """Return the keyword arguments that install the LZ4 filter on an
    ``h5py.create_dataset`` call. Requires the ``hdf5plugin`` package to
    be importable; raises ``RuntimeError`` otherwise with a pointer to
    the optional-dependency install command."""
    try:
        import hdf5plugin  # noqa: PLC0415
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "LZ4 compression requires the 'codecs' optional dependency; "
            "install with 'pip install mpeg-o[codecs]'"
        ) from exc
    return hdf5plugin.LZ4()


def write_signal_channel(
    group: h5py.Group,
    name: str,
    data: np.ndarray,
    chunk_size: int = DEFAULT_SIGNAL_CHUNK,
    compression_level: int = 6,
    *,
    compression: str = "gzip",
) -> h5py.Dataset:
    """Write a 1-D signal channel with the chosen compression codec.

    ``compression`` selects one of:

    - ``"gzip"`` (default, zlib) — matches the ObjC
      ``MPGOCompressionZlib`` default with ``compression_level``
      mapping to the deflate level.
    - ``"lz4"`` — HDF5 filter 32004 via ``hdf5plugin``. Raises
      ``RuntimeError`` when the plugin isn't installed.
    - ``"none"`` — chunked but uncompressed.

    Chunk size is clamped to ``len(data)`` when the dataset is shorter
    than ``chunk_size`` to match the ObjC writer.
    """
    if data.ndim != 1:
        raise ValueError(f"signal channel {name!r} must be 1-D, got shape={data.shape}")
    length = data.shape[0]
    if length == 0:
        return group.create_dataset(name, data=data)
    chunks = (min(chunk_size, length),)
    if compression == "gzip":
        return group.create_dataset(
            name, data=data, chunks=chunks,
            compression="gzip", compression_opts=compression_level,
        )
    if compression == "lz4":
        return group.create_dataset(
            name, data=data, chunks=chunks, **_lz4_filter_kwargs(),
        )
    if compression == "none":
        return group.create_dataset(name, data=data, chunks=chunks)
    raise ValueError(f"unknown compression codec {compression!r}")


def read_signal_channel(group: h5py.Group, name: str) -> np.ndarray:
    """Read a signal channel into a numpy array."""
    return group[name][()]


# ----------------------------------------------------- compound datasets ---


def vl_str() -> np.dtype:
    """Return an h5py variable-length string dtype suitable for compound
    members. Uses ASCII character set to match the Objective-C reference
    reader, whose ``H5T_C_S1`` copies default to ``H5T_CSET_ASCII``. HDF5
    has no built-in converter between ASCII and UTF-8 variable-length
    strings, so even though the payload bytes are identical for 7-bit
    data the character-set label must agree.
    """
    return h5py.string_dtype(encoding="ascii")


def write_compound_dataset(
    group: h5py.Group,
    name: str,
    records: Sequence[dict[str, Any]],
    fields: Sequence[tuple[str, Any]],
    compression_level: int = 6,
    *,
    align: bool = True,
) -> h5py.Dataset:
    """Write a 1-D compound dataset.

    ``fields`` is an ordered sequence of ``(name, numpy_dtype)`` pairs. Use
    :func:`vl_str` for variable-length UTF-8 string members. ``records`` is a
    sequence of dicts keyed by field name.

    ``align=True`` (the default) lays out the fields with C-struct padding
    so the on-disk compound matches the offsets the Objective-C reference
    reader expects. HDF5's type-conversion path refuses to bridge a
    densely packed compound to a padded one by field name, so the
    alignment must be correct on disk.
    """
    dtype = np.dtype([(fname, ftype) for fname, ftype in fields], align=align)
    arr = np.zeros(len(records), dtype=dtype)
    for i, rec in enumerate(records):
        for fname, _ in fields:
            arr[i][fname] = rec.get(fname, _zero_value_for(dtype[fname]))
    n = len(records)
    chunks: tuple[int, ...] | None
    if n == 0:
        chunks = None
        ds = group.create_dataset(name, data=arr, dtype=dtype)
    else:
        chunks = (min(DEFAULT_INDEX_CHUNK, n),)
        ds = group.create_dataset(
            name,
            data=arr,
            dtype=dtype,
            chunks=chunks,
            compression="gzip",
            compression_opts=compression_level,
        )
    return ds


def read_compound_dataset(group: h5py.Group, name: str) -> list[dict[str, Any]]:
    """Read a compound dataset into a list of dicts. Bytes VL strings are
    decoded to ``str``."""
    ds = group[name]
    arr = ds[()]
    out: list[dict[str, Any]] = []
    for row in arr:
        rec: dict[str, Any] = {}
        for fname in arr.dtype.names or ():
            raw = row[fname]
            if isinstance(raw, bytes):
                rec[fname] = raw.decode("utf-8")
            elif isinstance(raw, np.generic):
                rec[fname] = raw.item()
            else:
                rec[fname] = raw
        out.append(rec)
    return out


def _zero_value_for(dtype: np.dtype) -> Any:
    if dtype.kind in ("f",):
        return 0.0
    if dtype.kind in ("i", "u"):
        return 0
    if dtype.kind in ("O", "S", "U"):
        return ""
    return None


# --------------------------------------------------------- feature flags ---

FEATURES_ATTR = "mpeg_o_features"
VERSION_ATTR = "mpeg_o_format_version"
LEGACY_VERSION_ATTR = "mpeg_o_version"


def write_feature_flags(root: h5py.Group, version: str, features: Iterable[str]) -> None:
    """Write ``@mpeg_o_format_version`` and ``@mpeg_o_features`` on ``/``."""
    write_fixed_string_attr(root, VERSION_ATTR, version)
    write_fixed_string_attr(root, FEATURES_ATTR, json.dumps(list(features)))


def read_feature_flags(root: h5py.Group) -> tuple[str, list[str]]:
    """Read the pair with v0.1 legacy fallback.

    Returns ``("1.0.0", [])`` for files that carry only ``@mpeg_o_version``.
    """
    version = read_string_attr(root, VERSION_ATTR)
    features_json = read_string_attr(root, FEATURES_ATTR)
    if version is None and features_json is None:
        legacy = read_string_attr(root, LEGACY_VERSION_ATTR)
        if legacy is not None:
            return legacy, []
        return "1.0.0", []
    if features_json is None:
        return (version or "1.0.0"), []
    try:
        features = json.loads(features_json)
        if not isinstance(features, list):
            features = []
    except json.JSONDecodeError:
        features = []
    return (version or "1.0.0"), [str(f) for f in features]


def is_legacy_v1(root: h5py.Group) -> bool:
    """A file is v0.1-legacy when it has no ``@mpeg_o_features`` attribute."""
    return FEATURES_ATTR not in root.attrs
