"""Canonical byte-layout for cross-backend cryptographic hashing.

moves canonical-bytes generation from ``signatures.py`` (which
used h5py directly) into the storage provider protocol. Every backend
— HDF5, Memory, SQLite, future Zarr — emits the **same** bytes for the
same logical data so that a file signed through one provider verifies
through any other.

Canonical layout (stable across backends):

* **Primitive atomic dataset.** Values converted to little-endian and
  emitted contiguously via ``ndarray.tobytes()``. Endianness is
  explicit: on big-endian hosts (Power, s390x, older MIPS) the
  conversion is a real byteswap, not a no-op.
* **Compound dataset.** Walk rows in storage order; for each row, walk
  fields in declaration order:

    - numeric field → little-endian bytes of the field value
    - VL-string field → ``u32_le(byte_length) || utf-8_bytes``
    - unknown / fallback → ``numpy`` native bytes of the value

* **Unknown atomic class** (fixed strings, enums, nested compounds,
  ...) → native-bytes fallback. This matches the v0.2 ObjC signer
  for byte-identical v2 verification on legacy files.

Callers never construct these bytes themselves; they call
:meth:`ttio.providers.base.StorageDataset.read_canonical_bytes`.
"""
from __future__ import annotations

from typing import Any, Sequence

import numpy as np


def atomic_le_dtype(dt: np.dtype) -> np.dtype | None:
    """Return the little-endian twin of an atomic numeric dtype, or
    ``None`` if the dtype is not a recognised f/i/u kind."""
    if dt.kind == "f":
        if dt.itemsize == 4:
            return np.dtype("<f4")
        if dt.itemsize == 8:
            return np.dtype("<f8")
    if dt.kind == "i":
        return np.dtype(f"<i{dt.itemsize}")
    if dt.kind == "u":
        return np.dtype(f"<u{dt.itemsize}")
    return None


def canonicalise_primitive(arr: np.ndarray) -> bytes:
    """Canonical little-endian byte stream for a primitive ndarray."""
    target = atomic_le_dtype(arr.dtype)
    if target is None:
        return np.asarray(arr).tobytes()
    if arr.dtype == target:
        return arr.tobytes()
    return arr.astype(target, copy=False).tobytes()


def _encode_vl_string(value: Any) -> bytes:
    if isinstance(value, bytes):
        payload = value
    elif isinstance(value, str):
        payload = value.encode("utf-8")
    elif value is None:
        payload = b""
    else:
        payload = str(value).encode("utf-8")
    return len(payload).to_bytes(4, "little") + payload


def canonicalise_compound_structured(arr: np.ndarray) -> bytes:
    """Canonical bytes for a structured ndarray (HDF5 compound read).

    The array's dtype carries the field order and per-field kind;
    ``object``-kind fields are treated as VL strings, ``f/i/u`` fields
    are little-endian-normalised, everything else falls through to
    native bytes."""
    dt = arr.dtype
    field_names = dt.names or ()
    field_plan: list[tuple[str, bool, np.dtype | None]] = []
    for fname in field_names:
        fdt = dt.fields[fname][0]
        if fdt.kind == "O":
            field_plan.append((fname, True, None))
        elif fdt.kind in ("f", "i", "u"):
            field_plan.append((fname, False, atomic_le_dtype(fdt)))
        else:
            field_plan.append((fname, False, None))

    chunks: list[bytes] = []
    for row in arr:
        for fname, is_vl, target in field_plan:
            value = row[fname]
            if is_vl:
                chunks.append(_encode_vl_string(value))
            elif target is not None:
                chunks.append(np.asarray(value, dtype=target).tobytes())
            else:
                chunks.append(np.asarray(value).tobytes())
    return b"".join(chunks)


def canonicalise_compound_rows(
    rows: Sequence[dict[str, Any]],
    field_order: Sequence[str],
    field_kinds: Sequence[str],
) -> bytes:
    """Canonical bytes for ``list[dict]`` compound rows (SQLite / Memory
    read).

    ``field_kinds`` is a sequence of TTIO CompoundField.Kind identifiers
    (``"VL_STRING"``, ``"FLOAT64"``, ``"UINT32"``, ``"INT64"``). Emits
    the same byte sequence the structured-ndarray path produces when
    the dtype field-kinds match."""
    kind_to_le: dict[str, np.dtype] = {
        "FLOAT64": np.dtype("<f8"),
        "FLOAT32": np.dtype("<f4"),
        "UINT32": np.dtype("<u4"),
        "INT32": np.dtype("<i4"),
        "INT64": np.dtype("<i8"),
        "UINT64": np.dtype("<u8"),
    }
    chunks: list[bytes] = []
    for row in rows:
        for name, kind in zip(field_order, field_kinds):
            value = row.get(name)
            if kind == "VL_STRING":
                chunks.append(_encode_vl_string(value))
                continue
            le = kind_to_le.get(kind)
            if le is None:
                chunks.append(np.asarray(value).tobytes())
            else:
                chunks.append(np.asarray(value, dtype=le).tobytes())
    return b"".join(chunks)
