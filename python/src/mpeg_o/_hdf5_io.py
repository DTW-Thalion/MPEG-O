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
from typing import Any, Iterable, Sequence, Union

import h5py
import numpy as np

# v0.9 M64.5: the IO helpers below accept either a raw h5py object
# (legacy, byte-parity path) or a StorageGroup / StorageDataset from
# the provider abstraction. For HDF5-backed providers we unwrap back
# to h5py so on-disk layout is unchanged. For Memory/SQLite/Zarr the
# protocol methods are used.
from .providers.base import StorageDataset, StorageGroup


# Any object the helpers know how to read/write against.
_IOTarget = Union[h5py.HLObject, StorageGroup, StorageDataset]


def _unwrap_to_h5py(obj: _IOTarget) -> h5py.HLObject | None:
    """Return the native h5py object for HDF5-backed StorageGroup /
    StorageDataset values; ``None`` for non-HDF5 providers. Leaves a
    raw h5py input unchanged."""
    if isinstance(obj, (StorageGroup, StorageDataset)):
        # Hdf5Provider's _Group / _Dataset expose the underlying h5py
        # object as ``_grp`` / ``_ds`` respectively. Non-HDF5 providers
        # don't have these attributes.
        native = getattr(obj, "_grp", None) or getattr(obj, "_ds", None)
        return native
    return obj


# ------------------------------------------------------------------ attrs ---


def _as_bytes(value: str) -> bytes:
    """Encode to UTF-8 bytes, empty-string tolerant."""
    return value.encode("utf-8") if value else b""


def write_fixed_string_attr(obj: _IOTarget, name: str, value: str) -> None:
    """Write a fixed-length NULLTERM string attribute matching ObjC layout.

    If the attribute already exists it is deleted and recreated, because the
    size of an existing attribute cannot be changed in place. Non-HDF5
    providers store the value via :meth:`StorageGroup.set_attribute`
    (byte layout is provider-specific there).
    """
    native = _unwrap_to_h5py(obj)
    if native is None:
        obj.set_attribute(name, value)
        return
    data = _as_bytes(value)
    size = len(data) + 1  # reserve the byte h5py insists on for NULLTERM
    tid = h5py.h5t.C_S1.copy()
    tid.set_size(size)
    tid.set_strpad(h5py.h5t.STR_NULLTERM)
    space = h5py.h5s.create(h5py.h5s.SCALAR)
    nbytes = name.encode("utf-8")
    if h5py.h5a.exists(native.id, nbytes):
        h5py.h5a.delete(native.id, nbytes)
    aid = h5py.h5a.create(native.id, nbytes, tid, space)
    padded = data + b"\x00"
    buf = np.frombuffer(padded, dtype="|S%d" % size).copy()
    aid.write(buf)
    aid.close()


def read_string_attr(obj: _IOTarget, name: str, default: str | None = None) -> str | None:
    """Read a string attribute, tolerating bytes / numpy scalar forms.

    Returns ``default`` if the attribute is absent.
    """
    native = _unwrap_to_h5py(obj)
    if native is None:
        if not obj.has_attribute(name):
            return default
        raw = obj.get_attribute(name)
    else:
        if name not in native.attrs:
            return default
        raw = native.attrs[name]
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


def write_int_attr(obj: _IOTarget, name: str, value: int, dtype: str = "<i8") -> None:
    native = _unwrap_to_h5py(obj)
    if native is None:
        obj.set_attribute(name, int(value))
        return
    native.attrs.create(name, np.array(value, dtype=dtype))


def read_int_attr(obj: _IOTarget, name: str, default: int | None = None) -> int | None:
    native = _unwrap_to_h5py(obj)
    if native is None:
        if not obj.has_attribute(name):
            return default
        return int(obj.get_attribute(name))
    if name not in native.attrs:
        return default
    return int(native.attrs[name])


# ------------------------------------------------------ signal channels ---

DEFAULT_SIGNAL_CHUNK = 65536
DEFAULT_INDEX_CHUNK = 4096


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
    group: _IOTarget,
    name: str,
    data: np.ndarray,
    chunk_size: int = DEFAULT_SIGNAL_CHUNK,
    compression_level: int = 6,
    *,
    compression: str = "gzip",
) -> Any:
    """Write a 1-D signal channel with the chosen compression codec.

    ``compression`` selects one of:

    - ``"gzip"`` (default, zlib) — matches the ObjC
      ``MPGOCompressionZlib`` default with ``compression_level``
      mapping to the deflate level.
    - ``"lz4"`` — HDF5 filter 32004 via ``hdf5plugin``. Raises
      ``RuntimeError`` when the plugin isn't installed (HDF5 only —
      non-HDF5 providers fall back to no compression).
    - ``"none"`` — chunked but uncompressed.

    Chunk size is clamped to ``len(data)`` when the dataset is shorter
    than ``chunk_size`` to match the ObjC writer.
    """
    if data.ndim != 1:
        raise ValueError(f"signal channel {name!r} must be 1-D, got shape={data.shape}")
    length = data.shape[0]
    native = _unwrap_to_h5py(group)
    if native is None:
        # Non-HDF5 provider: use the StorageGroup protocol.
        from .enums import Compression, Precision
        precision = _precision_from_dtype(data.dtype)
        codec = {
            "gzip": Compression.ZLIB,
            "lz4": Compression.LZ4,
            "none": Compression.NONE,
        }.get(compression, Compression.ZLIB)
        chunk = min(chunk_size, length) if length else 0
        ds = group.create_dataset(
            name, precision, length,
            chunk_size=chunk,
            compression=codec,
            compression_level=compression_level,
        )
        if length:
            ds.write(np.ascontiguousarray(data))
        return ds
    # HDF5 legacy fast path — byte-parity preserved.
    if length == 0:
        return native.create_dataset(name, data=data)
    chunks = (min(chunk_size, length),)
    if compression == "gzip":
        return native.create_dataset(
            name, data=data, chunks=chunks,
            compression="gzip", compression_opts=compression_level,
        )
    if compression == "lz4":
        return native.create_dataset(
            name, data=data, chunks=chunks, **_lz4_filter_kwargs(),
        )
    if compression == "none":
        return native.create_dataset(name, data=data, chunks=chunks)
    raise ValueError(f"unknown compression codec {compression!r}")


def _precision_from_dtype(dt: np.dtype) -> Any:
    """Map a numpy dtype to the Precision enum used by StorageGroup.

    v0.9: ``<u8`` (uint64) maps to INT64 because the Precision enum
    has no UINT64 entry and .mpgo spectrum_index offsets are always
    non-negative and < 2^63, so the on-disk byte layout is identical.
    This keeps offsets readable as INT64 columns by the Java
    ``SqliteProvider`` (which rejected the prior FLOAT64 fallback with
    ``class [D cannot be cast to class [J``). Python's
    ``SpectrumIndex.read`` already reinterprets the int64 back as
    ``<u8`` via ``astype``.
    """
    from .enums import Precision
    by_str = {
        "<f4": Precision.FLOAT32, "<f8": Precision.FLOAT64,
        "<i4": Precision.INT32,  "<i8": Precision.INT64,
        "<u8": Precision.INT64,  # v0.9: uint64 → int64 (see docstring)
        "<u4": Precision.UINT32,
    }
    return by_str.get(dt.str, Precision.FLOAT64)


def read_signal_channel(group: _IOTarget, name: str) -> np.ndarray:
    """Read a signal channel into a numpy array."""
    native = _unwrap_to_h5py(group)
    if native is None:
        return np.asarray(group.open_dataset(name).read())
    return native[name][()]


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
    group: _IOTarget,
    name: str,
    records: Sequence[dict[str, Any]],
    fields: Sequence[tuple[str, Any]],
    compression_level: int = 6,
    *,
    align: bool = True,
) -> Any:
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
    native = _unwrap_to_h5py(group)
    if native is None:
        # Non-HDF5 provider: translate field tuples to CompoundField
        # descriptors and route through StorageGroup. ``ftype`` may be
        # an h5py vl-string dtype (from io.vl_str()), a numpy dtype,
        # or a dtype string like ``"<u4"``; check_string_dtype only
        # accepts an actual dtype, so coerce first.
        from .providers.base import CompoundField, CompoundFieldKind
        compound_fields: list[CompoundField] = []
        for fname, ftype in fields:
            try:
                dt = np.dtype(ftype)
            except TypeError:
                dt = None
            is_vl_string = (dt is not None
                              and h5py.check_string_dtype(dt) is not None)
            if is_vl_string:
                kind = CompoundFieldKind.VL_STRING
            elif dt is not None:
                if dt.str == "<u4":
                    kind = CompoundFieldKind.UINT32
                elif dt.str == "<i8":
                    kind = CompoundFieldKind.INT64
                elif dt.str == "<f8":
                    kind = CompoundFieldKind.FLOAT64
                else:
                    kind = CompoundFieldKind.FLOAT64
            else:
                kind = CompoundFieldKind.FLOAT64
            compound_fields.append(CompoundField(name=fname, kind=kind))
        ds = group.create_compound_dataset(name, compound_fields, len(records))
        if records:
            ds.write(list(records))
        return ds
    dtype = np.dtype([(fname, ftype) for fname, ftype in fields], align=align)
    arr = np.zeros(len(records), dtype=dtype)
    for i, rec in enumerate(records):
        for fname, _ in fields:
            arr[i][fname] = rec.get(fname, _zero_value_for(dtype[fname]))
    n = len(records)
    chunks: tuple[int, ...] | None
    if n == 0:
        chunks = None
        ds = native.create_dataset(name, data=arr, dtype=dtype)
    else:
        chunks = (min(DEFAULT_INDEX_CHUNK, n),)
        ds = native.create_dataset(
            name,
            data=arr,
            dtype=dtype,
            chunks=chunks,
            compression="gzip",
            compression_opts=compression_level,
        )
    return ds


def read_compound_dataset(group: _IOTarget, name: str) -> list[dict[str, Any]]:
    """Read a compound dataset into a list of dicts. Bytes VL strings are
    decoded to ``str``."""
    native = _unwrap_to_h5py(group)
    if native is None:
        return list(group.open_dataset(name).read_rows())
    ds = native[name]
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


def write_feature_flags(root: _IOTarget, version: str, features: Iterable[str]) -> None:
    """Write ``@mpeg_o_format_version`` and ``@mpeg_o_features`` on ``/``."""
    write_fixed_string_attr(root, VERSION_ATTR, version)
    write_fixed_string_attr(root, FEATURES_ATTR, json.dumps(list(features)))


def read_feature_flags(root: _IOTarget) -> tuple[str, list[str]]:
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


def is_legacy_v1(root: _IOTarget) -> bool:
    """A file is v0.1-legacy when it has no ``@mpeg_o_features`` attribute."""
    native = _unwrap_to_h5py(root)
    if native is None:
        return not root.has_attribute(FEATURES_ATTR)
    return FEATURES_ATTR not in native.attrs


# ---------------------------------------------------------------------
# v1.0 per-AU encryption: compound-dataset I/O
# ---------------------------------------------------------------------
# See docs/transport-encryption-design.md §5 + format-spec §9.1.
# Layout:
#   channel segments    — {offset u64, length u32, iv u8[12], tag u8[16],
#                           ciphertext VL u8}
#   au_header segments  — {iv u8[12], tag u8[16], ciphertext u8[36]}


def _channel_segments_dtype():
    return np.dtype([
        ('offset', '<u8'),
        ('length', '<u4'),
        ('iv', 'u1', (12,)),
        ('tag', 'u1', (16,)),
        ('ciphertext', h5py.vlen_dtype(np.uint8)),
    ])


def _au_header_segments_dtype():
    return np.dtype([
        ('iv', 'u1', (12,)),
        ('tag', 'u1', (16,)),
        ('ciphertext', 'u1', (36,)),
    ])


def write_channel_segments(parent: _IOTarget, name: str, segments):
    Write


# ---------------------------------------------------------------------
# v1.0 per-AU encryption: compound-dataset I/O
# ---------------------------------------------------------------------
# See docs/transport-encryption-design.md §5 + format-spec §9.1.
# Layout:
#   channel segments    - {offset u64, length u32, iv u8[12], tag u8[16],
#                          ciphertext VL u8}
#   au_header segments  - {iv u8[12], tag u8[16], ciphertext u8[36]}


def _channel_segments_dtype():
    return np.dtype([
        ("offset", "<u8"),
        ("length", "<u4"),
        ("iv", "u1", (12,)),
        ("tag", "u1", (16,)),
        ("ciphertext", h5py.vlen_dtype(np.uint8)),
    ])


def _au_header_segments_dtype():
    return np.dtype([
        ("iv", "u1", (12,)),
        ("tag", "u1", (16,)),
        ("ciphertext", "u1", (36,)),
    ])


def write_channel_segments(parent, name, segments):
    """Write a ChannelSegment list as one compound HDF5 dataset.

    ``segments`` iterable of objects with attributes offset (int),
    length (int), iv (12 bytes), tag (16 bytes), ciphertext (bytes).
    See docs/format-spec.md §9.1.
    """
    native = _unwrap_to_h5py(parent)
    if native is None:
        raise NotImplementedError(
            "write_channel_segments: non-HDF5 providers not yet supported"
        )
    rows = list(segments)
    dtype = _channel_segments_dtype()
    arr = np.empty(len(rows), dtype=dtype)
    for i, seg in enumerate(rows):
        arr[i]["offset"] = int(seg.offset)
        arr[i]["length"] = int(seg.length)
        arr[i]["iv"] = np.frombuffer(seg.iv, dtype=np.uint8)
        arr[i]["tag"] = np.frombuffer(seg.tag, dtype=np.uint8)
        arr[i]["ciphertext"] = np.frombuffer(bytes(seg.ciphertext), dtype=np.uint8)
    if name in native:
        del native[name]
    return native.create_dataset(name, data=arr, dtype=dtype)


def read_channel_segments(parent, name):
    """Reverse of write_channel_segments."""
    native = _unwrap_to_h5py(parent)
    if native is None or name not in native:
        raise KeyError(f"channel segments dataset {name!r} not found")
    from types import SimpleNamespace
    arr = native[name][()]
    rows = []
    for row in arr:
        rows.append(SimpleNamespace(
            offset=int(row["offset"]),
            length=int(row["length"]),
            iv=bytes(row["iv"]),
            tag=bytes(row["tag"]),
            ciphertext=bytes(row["ciphertext"]),
        ))
    return rows


def write_au_header_segments(parent, name, segments):
    """Write HeaderSegment list as a compound dataset (fixed 36-byte
    ciphertext per row)."""
    native = _unwrap_to_h5py(parent)
    if native is None:
        raise NotImplementedError(
            "write_au_header_segments: non-HDF5 providers not yet supported"
        )
    rows = list(segments)
    dtype = _au_header_segments_dtype()
    arr = np.empty(len(rows), dtype=dtype)
    for i, seg in enumerate(rows):
        arr[i]["iv"] = np.frombuffer(seg.iv, dtype=np.uint8)
        arr[i]["tag"] = np.frombuffer(seg.tag, dtype=np.uint8)
        arr[i]["ciphertext"] = np.frombuffer(bytes(seg.ciphertext), dtype=np.uint8)
    if name in native:
        del native[name]
    return native.create_dataset(name, data=arr, dtype=dtype)


def read_au_header_segments(parent, name):
    """Reverse of write_au_header_segments."""
    native = _unwrap_to_h5py(parent)
    if native is None or name not in native:
        raise KeyError(f"au_header segments dataset {name!r} not found")
    from types import SimpleNamespace
    arr = native[name][()]
    rows = []
    for row in arr:
        rows.append(SimpleNamespace(
            iv=bytes(row["iv"]),
            tag=bytes(row["tag"]),
            ciphertext=bytes(row["ciphertext"]),
        ))
    return rows
