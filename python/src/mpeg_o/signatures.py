"""HMAC-SHA256 digital signatures matching the ObjC reference implementation.

v0.2 (``v1`` in this file) signed over the raw bytes returned by
``H5Dread`` in the dataset's native memory type; on little-endian hosts
that happens to be the same as the canonical form, but signatures would
not validate across host endianness. v0.3 introduces a ``v2`` canonical
form that normalizes atomic numeric datasets to little-endian before
hashing and emits compound records with a fixed per-field layout
(little-endian numerics plus ``u32_le(length) || bytes`` for VL strings).

Stored signatures carry a ``v2:`` prefix; verifiers accept unprefixed
``v1`` signatures for backward compatibility and silently route them
through the native-bytes path.

The format is fully interoperable with the Objective-C reference
implementation — see ``objc/Source/Protection/MPGOSignatureManager.m``.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
from typing import Any

import h5py
import numpy as np

SIGNATURE_ATTR = "mpgo_signature"
PROVENANCE_SIGNATURE_ATTR = "provenance_signature"
SIGNATURE_V2_PREFIX = "v2:"


def hmac_sha256(data: bytes, key: bytes) -> bytes:
    """Return the raw 32-byte HMAC-SHA256 MAC."""
    return hmac.new(key, data, hashlib.sha256).digest()


def hmac_sha256_b64(data: bytes, key: bytes) -> str:
    """Return the base64-encoded MAC as produced by the ObjC writer."""
    return base64.b64encode(hmac_sha256(data, key)).decode("ascii")


# ---------------------------------------------------- dataset signatures ---


def _dataset_native_bytes(dataset: h5py.Dataset) -> bytes:
    """Return the raw dataset bytes in native type order (v1 path).

    Matches ``H5Dread`` with the file's native memory type, which is
    what the v0.2 ObjC signer hashed over. h5py's ``dataset[()]`` already
    performs the read; we just take the underlying buffer. This path is
    retained purely for backward compatibility with v0.2 files.
    """
    arr = dataset[()]
    if isinstance(arr, np.ndarray):
        return arr.tobytes()
    return np.asarray(arr).tobytes()


def _dataset_canonical_bytes(dataset: h5py.Dataset) -> bytes:
    """Return the canonical little-endian byte stream for ``dataset`` (v2).

    Atomic numeric datasets are cast to their little-endian equivalent
    and serialized via ``ndarray.tobytes()``. Compound datasets are
    walked field by field: numeric members are emitted in little-endian
    byte order and VL strings are emitted as ``u32_le(length) || bytes``.
    Any unsupported class (fixed strings, enums, nested compounds, ...)
    falls back to the native-bytes form, matching the ObjC fallback.
    """
    file_dtype = dataset.dtype
    if file_dtype.names:
        return _compound_canonical_bytes(dataset)
    kind = file_dtype.kind
    if kind in ("f", "i", "u"):
        target = _atomic_le_dtype(file_dtype)
        if target is None:
            return _dataset_native_bytes(dataset)
        arr = dataset[()].astype(target, copy=False)
        return arr.tobytes()
    return _dataset_native_bytes(dataset)


def _atomic_le_dtype(dt: np.dtype) -> np.dtype | None:
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


def _compound_canonical_bytes(dataset: h5py.Dataset) -> bytes:
    """Walk a compound dataset and emit the canonical M18 byte stream."""
    arr = dataset[()]
    dt = arr.dtype
    field_names = dt.names or ()

    # Pre-compute per-field handling: (is_vl_string, le_dtype_or_None)
    field_plan: list[tuple[str, bool, np.dtype | None]] = []
    for fname in field_names:
        fdt = dt.fields[fname][0]
        if fdt.kind == "O":
            field_plan.append((fname, True, None))
        elif fdt.kind in ("f", "i", "u"):
            field_plan.append((fname, False, _atomic_le_dtype(fdt)))
        else:
            field_plan.append((fname, False, None))

    chunks: list[bytes] = []
    for row in arr:
        for fname, is_vl, target in field_plan:
            value = row[fname]
            if is_vl:
                if isinstance(value, bytes):
                    payload = value
                elif isinstance(value, str):
                    payload = value.encode("utf-8")
                elif value is None:
                    payload = b""
                else:
                    payload = str(value).encode("utf-8")
                chunks.append(len(payload).to_bytes(4, "little"))
                if payload:
                    chunks.append(payload)
            elif target is not None:
                chunks.append(np.asarray(value, dtype=target).tobytes())
            else:
                # Unknown class — fall through to numpy's native bytes.
                chunks.append(np.asarray(value).tobytes())
    return b"".join(chunks)


def sign_dataset(dataset: h5py.Dataset, key: bytes) -> str:
    """Sign ``dataset`` with a canonical (v2) HMAC-SHA256 signature.

    The resulting attribute string carries a ``v2:`` prefix. Use
    :func:`verify_dataset` to validate; it transparently falls back to
    the v0.2 unprefixed native-bytes path for legacy files.
    """
    mac_b64 = hmac_sha256_b64(_dataset_canonical_bytes(dataset), key)
    prefixed = SIGNATURE_V2_PREFIX + mac_b64
    _write_vl_string_attr(dataset, SIGNATURE_ATTR, prefixed)
    return prefixed


def verify_dataset(dataset: h5py.Dataset, key: bytes) -> bool:
    """Verify the stored ``@mpgo_signature`` against ``key``.

    Accepts both the v0.3 ``v2:`` canonical layout and the v0.2 native
    layout; the prefix distinguishes the two. Uses timing-safe
    comparison via :func:`hmac.compare_digest`.
    """
    stored = _read_vl_string_attr(dataset, SIGNATURE_ATTR)
    if stored is None:
        return False
    if stored.startswith(SIGNATURE_V2_PREFIX):
        payload = stored[len(SIGNATURE_V2_PREFIX):]
        expected = hmac_sha256_b64(_dataset_canonical_bytes(dataset), key)
    else:
        payload = stored
        expected = hmac_sha256_b64(_dataset_native_bytes(dataset), key)
    return hmac.compare_digest(payload, expected)


def verify_provenance(run_group: h5py.Group, key: bytes) -> bool:
    """Verify the ``@provenance_signature`` over ``@provenance_json``."""
    stored = _read_vl_string_attr(run_group, PROVENANCE_SIGNATURE_ATTR)
    if stored is None:
        return False
    prov_json = _read_vl_string_attr(run_group, "provenance_json") or ""
    expected = hmac_sha256_b64(prov_json.encode("utf-8"), key)
    return hmac.compare_digest(stored, expected)


# --------------------------------------------------- VL string attr helpers ---


def _write_vl_string_attr(obj: Any, name: str, value: str) -> None:
    """Write a variable-length UTF-8 string attribute (for parity with the
    ObjC signature writer which uses ``H5T_VARIABLE``).
    """
    nbytes = name.encode("utf-8")
    if h5py.h5a.exists(obj.id, nbytes):
        h5py.h5a.delete(obj.id, nbytes)
    tid = h5py.h5t.C_S1.copy()
    tid.set_size(h5py.h5t.VARIABLE)
    tid.set_strpad(h5py.h5t.STR_NULLTERM)
    tid.set_cset(h5py.h5t.CSET_UTF8)
    space = h5py.h5s.create(h5py.h5s.SCALAR)
    aid = h5py.h5a.create(obj.id, nbytes, tid, space)
    aid.write(np.array([value.encode("utf-8")], dtype=h5py.string_dtype()))
    aid.close()


def _read_vl_string_attr(obj: Any, name: str) -> str | None:
    if name not in obj.attrs:
        return None
    raw = obj.attrs[name]
    if isinstance(raw, bytes):
        return raw.decode("utf-8")
    if isinstance(raw, np.bytes_):
        return raw.tobytes().decode("utf-8")
    if isinstance(raw, str):
        return raw
    return str(raw)
