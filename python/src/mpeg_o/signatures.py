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

Cross-language equivalents
--------------------------
Objective-C: ``MPGOSignatureManager`` · Java:
``com.dtwthalion.mpgo.protection.SignatureManager``.

API status: Stable.
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

    v0.7 M43: this helper now delegates to the storage-provider
    protocol's :meth:`StorageDataset.read_canonical_bytes`, so the byte
    stream is guaranteed bit-identical across HDF5, Memory, and SQLite
    backends — a file signed through any provider verifies through any
    other. The HDF5 path still runs its optimised native-dtype walk via
    the :class:`mpeg_o.providers.hdf5._Dataset` override.
    """
    from .providers.hdf5 import _Dataset as _Hdf5Dataset
    return _Hdf5Dataset(dataset).read_canonical_bytes()


def sign_dataset(
    dataset: h5py.Dataset,
    key: bytes,
    *,
    algorithm: str = "hmac-sha256",
) -> str:
    """Sign ``dataset`` with a canonical (v2) signature.

    The resulting attribute string carries a ``v2:`` prefix for
    HMAC-SHA256 (default). Post-quantum signature algorithms (M49)
    will reserve a ``v3:`` prefix. Use :func:`verify_dataset` to
    validate; it transparently falls back to the v0.2 unprefixed
    native-bytes path for legacy files.

    v0.7 M48: ``algorithm`` is the catalog identifier
    (``"hmac-sha256"`` active; ``"ml-dsa-87"`` reserved). Unsupported
    or unknown identifiers raise
    :class:`~mpeg_o.cipher_suite.UnsupportedAlgorithmError`.
    """
    from . import cipher_suite
    cipher_suite.validate_key(algorithm, key)
    if algorithm != "hmac-sha256":
        raise cipher_suite.UnsupportedAlgorithmError(
            f"{algorithm}: signature path not yet implemented "
            f"(M49 target)"
        )
    mac_b64 = hmac_sha256_b64(_dataset_canonical_bytes(dataset), key)
    prefixed = SIGNATURE_V2_PREFIX + mac_b64
    _write_vl_string_attr(dataset, SIGNATURE_ATTR, prefixed)
    return prefixed


def verify_dataset(
    dataset: h5py.Dataset,
    key: bytes,
    *,
    algorithm: str = "hmac-sha256",
) -> bool:
    """Verify the stored ``@mpgo_signature`` against ``key``.

    Accepts both the v0.3 ``v2:`` canonical layout and the v0.2 native
    layout; the prefix distinguishes the two. Uses timing-safe
    comparison via :func:`hmac.compare_digest`.

    v0.7 M48: the ``algorithm`` parameter mirrors :func:`sign_dataset`.
    A ``"v3:"`` prefix encountered during verification raises
    :class:`~mpeg_o.cipher_suite.UnsupportedAlgorithmError` — M49 will
    activate ML-DSA-87 verification.
    """
    from . import cipher_suite
    cipher_suite.validate_key(algorithm, key)
    if algorithm != "hmac-sha256":
        raise cipher_suite.UnsupportedAlgorithmError(
            f"{algorithm}: signature path not yet implemented "
            f"(M49 target)"
        )
    stored = _read_vl_string_attr(dataset, SIGNATURE_ATTR)
    if stored is None:
        return False
    if stored.startswith("v3:"):
        # Reserved for M49. Fail the verify cleanly rather than
        # silently passing — forcing callers to upgrade to a PQC
        # build to read PQC-signed files.
        raise cipher_suite.UnsupportedAlgorithmError(
            "v3: signature prefix reserved for post-quantum "
            "algorithms (M49); this build cannot verify it"
        )
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
