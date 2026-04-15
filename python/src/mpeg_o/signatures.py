"""HMAC-SHA256 digital signatures matching the ObjC reference implementation.

The ObjC side computes an HMAC-SHA256 over the raw bytes returned by
``H5Dread`` in the dataset's native type. For little-endian hosts (the
common case) that's the same as reading the dataset via h5py and hashing
its ``.tobytes()`` — so v0.2 signed files can be verified from Python on
any x86_64 or arm64 machine. The M18 canonical-byte-order pass will make
this portable across architectures.

Signatures are base64-encoded and stored as a variable-length UTF-8 string
attribute ``@mpgo_signature`` on the signed dataset (or
``@provenance_signature`` on a run group).
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


def hmac_sha256(data: bytes, key: bytes) -> bytes:
    """Return the raw 32-byte HMAC-SHA256 MAC."""
    return hmac.new(key, data, hashlib.sha256).digest()


def hmac_sha256_b64(data: bytes, key: bytes) -> str:
    """Return the base64-encoded MAC as produced by the ObjC writer."""
    return base64.b64encode(hmac_sha256(data, key)).decode("ascii")


# ---------------------------------------------------- dataset signatures ---


def _dataset_native_bytes(dataset: h5py.Dataset) -> bytes:
    """Return the raw dataset bytes in native type order.

    Matches ``H5Dread`` with the native memory type that the ObjC signature
    code uses. h5py's ``dataset[()]`` already performs the read; we just take
    the underlying buffer.
    """
    arr = dataset[()]
    if isinstance(arr, np.ndarray):
        return arr.tobytes()
    # Scalar or compound: fall back to numpy conversion
    return np.asarray(arr).tobytes()


def sign_dataset(dataset: h5py.Dataset, key: bytes) -> str:
    """Compute and store an HMAC-SHA256 signature over ``dataset``.

    Writes the base64 MAC as a VL UTF-8 string attribute named
    ``@mpgo_signature`` and returns it.
    """
    mac_b64 = hmac_sha256_b64(_dataset_native_bytes(dataset), key)
    _write_vl_string_attr(dataset, SIGNATURE_ATTR, mac_b64)
    return mac_b64


def verify_dataset(dataset: h5py.Dataset, key: bytes) -> bool:
    """Check the ``@mpgo_signature`` attribute on ``dataset`` against ``key``.

    Returns ``True`` iff the attribute exists and matches. Timing-safe
    comparison via :func:`hmac.compare_digest`.
    """
    stored = _read_vl_string_attr(dataset, SIGNATURE_ATTR)
    if stored is None:
        return False
    expected = hmac_sha256_b64(_dataset_native_bytes(dataset), key)
    return hmac.compare_digest(stored, expected)


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
