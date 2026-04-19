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
import warnings
from typing import Any

import h5py
import numpy as np

SIGNATURE_ATTR = "mpgo_signature"
PROVENANCE_SIGNATURE_ATTR = "provenance_signature"
SIGNATURE_V2_PREFIX = "v2:"
SIGNATURE_V3_PREFIX = "v3:"  # ML-DSA-87, v0.8 M49


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
    dataset: Any,
    key: bytes,
    *,
    algorithm: str = "hmac-sha256",
) -> str:
    """Sign ``dataset`` with a canonical signature.

    For ``algorithm="hmac-sha256"`` (default) ``key`` is a shared secret
    and the output is ``"v2:" + base64(hmac)``. For
    ``algorithm="ml-dsa-87"`` (v0.8 M49) ``key`` is the 4896-byte
    ML-DSA-87 signing private key and the output is
    ``"v3:" + base64(signature)``. Use :func:`verify_dataset` to
    validate; it dispatches on the stored prefix.

    v0.9 M64.5 phase B: ``dataset`` may be either an ``h5py.Dataset``
    (legacy fast path) or a :class:`StorageDataset` from any provider.
    Non-h5py inputs delegate to :func:`sign_storage_dataset` so the
    same signature ends up on Memory / SQLite / Zarr backends.

    v0.8 M49: ML-DSA-87 requires the ``[pqc]`` optional extra (Python /
    ObjC backend is ``liboqs``; Java uses Bouncy Castle — see
    :file:`docs/pqc.md`).
    """
    from .providers.base import StorageDataset
    if isinstance(dataset, StorageDataset):
        return sign_storage_dataset(dataset, key, algorithm=algorithm)
    from . import cipher_suite
    canonical = _dataset_canonical_bytes(dataset)
    if algorithm == "hmac-sha256":
        cipher_suite.validate_key(algorithm, key)
        mac_b64 = hmac_sha256_b64(canonical, key)
        prefixed = SIGNATURE_V2_PREFIX + mac_b64
    elif algorithm == "ml-dsa-87":
        cipher_suite.validate_private_key(algorithm, key)
        from . import pqc
        sig = pqc.sig_sign(key, canonical)
        prefixed = SIGNATURE_V3_PREFIX + base64.b64encode(sig).decode("ascii")
    else:
        raise cipher_suite.UnsupportedAlgorithmError(
            f"{algorithm}: signature path not yet implemented"
        )
    _write_vl_string_attr(dataset, SIGNATURE_ATTR, prefixed)
    return prefixed


def verify_dataset(
    dataset: Any,
    key: bytes,
    *,
    algorithm: str = "hmac-sha256",
) -> bool:
    """Verify the stored ``@mpgo_signature`` against ``key``.

    Accepts v0.2 unprefixed HMAC (native-bytes path), v0.3 ``v2:``
    canonical HMAC, and v0.8 ``v3:`` ML-DSA-87 signatures. Uses
    timing-safe comparison for HMAC; ML-DSA verification itself runs
    in constant time via liboqs.

    v0.9 M64.5 phase B: ``dataset`` may be either an ``h5py.Dataset``
    or a :class:`StorageDataset`; non-h5py inputs delegate to
    :func:`verify_storage_dataset`.

    The ``algorithm`` keyword tells the verifier what key shape to
    expect. If the on-disk prefix does not match, raises
    :class:`~mpeg_o.cipher_suite.UnsupportedAlgorithmError` so callers
    don't silently pass verification of a file encrypted with a
    different algorithm. For ML-DSA-87, ``key`` is the 2592-byte
    verification public key.
    """
    from .providers.base import StorageDataset
    if isinstance(dataset, StorageDataset):
        return verify_storage_dataset(dataset, key, algorithm=algorithm)
    from . import cipher_suite
    stored = _read_vl_string_attr(dataset, SIGNATURE_ATTR)
    if stored is None:
        return False

    canonical = _dataset_canonical_bytes(dataset)

    if stored.startswith(SIGNATURE_V3_PREFIX):
        if algorithm != "ml-dsa-87":
            raise cipher_suite.UnsupportedAlgorithmError(
                f"stored signature is v3 (ml-dsa-87) but caller "
                f"passed algorithm={algorithm!r}"
            )
        cipher_suite.validate_public_key(algorithm, key)
        from . import pqc
        sig = base64.b64decode(stored[len(SIGNATURE_V3_PREFIX):])
        return pqc.sig_verify(key, canonical, sig)

    # Reject caller passing "ml-dsa-87" against a non-v3 stored blob —
    # saves a confusing empty-verify return.
    if algorithm == "ml-dsa-87":
        raise cipher_suite.UnsupportedAlgorithmError(
            "stored signature is not v3 (ml-dsa-87) — pass "
            "algorithm='hmac-sha256' to verify legacy signatures"
        )
    cipher_suite.validate_key(algorithm, key)
    if stored.startswith(SIGNATURE_V2_PREFIX):
        payload = stored[len(SIGNATURE_V2_PREFIX):]
        expected = hmac_sha256_b64(canonical, key)
    else:
        # v0.2 legacy path — unprefixed base64 HMAC over the native
        # byte layout. Scheduled for removal at v1.0 per
        # docs/api-stability-v0.8.md §6.
        warnings.warn(
            "verifying an unprefixed v1 HMAC signature — the v0.2 "
            "native-byte fallback is scheduled for removal at v1.0. "
            "Re-sign with algorithm='hmac-sha256' (emits v2: prefix) "
            "or 'ml-dsa-87' (v3:) to stay compatible.",
            DeprecationWarning,
            stacklevel=2,
        )
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


# ── Provider-agnostic sign / verify (v0.8 M54.1) ─────────────────────────


def sign_storage_dataset(
    dataset: Any,
    key: bytes,
    *,
    algorithm: str = "hmac-sha256",
) -> str:
    """Sign any :class:`~mpeg_o.providers.base.StorageDataset` with the
    named algorithm.

    Mirrors :func:`sign_dataset` (h5py-native) but works across every
    provider — HDF5, Memory, SQLite, Zarr. The canonical byte stream
    comes from :meth:`StorageDataset.read_canonical_bytes` so the
    signature is identical regardless of backend.

    Used by the M54.1 cross-language conformance matrix. The dataset
    must support ``set_attribute("mpgo_signature", str)`` — every
    shipping provider does.

    @since 0.8 (v0.8 M54.1)
    """
    from . import cipher_suite
    canonical = dataset.read_canonical_bytes()
    if algorithm == "hmac-sha256":
        cipher_suite.validate_key(algorithm, key)
        mac_b64 = hmac_sha256_b64(canonical, key)
        prefixed = SIGNATURE_V2_PREFIX + mac_b64
    elif algorithm == "ml-dsa-87":
        cipher_suite.validate_private_key(algorithm, key)
        from . import pqc
        sig = pqc.sig_sign(key, canonical)
        prefixed = SIGNATURE_V3_PREFIX + base64.b64encode(sig).decode("ascii")
    else:
        raise cipher_suite.UnsupportedAlgorithmError(
            f"{algorithm}: signature path not yet implemented"
        )
    dataset.set_attribute(SIGNATURE_ATTR, prefixed)
    return prefixed


def verify_storage_dataset(
    dataset: Any,
    key: bytes,
    *,
    algorithm: str = "hmac-sha256",
) -> bool:
    """Verify any :class:`~mpeg_o.providers.base.StorageDataset`'s
    stored ``@mpgo_signature``.

    Prefix/algorithm must match — a ``v3:`` attribute with
    ``algorithm="hmac-sha256"`` raises
    :class:`~mpeg_o.cipher_suite.UnsupportedAlgorithmError` so silent
    acceptance of a wrong-scheme file is impossible.

    @since 0.8 (v0.8 M54.1)
    """
    from . import cipher_suite
    if not dataset.has_attribute(SIGNATURE_ATTR):
        return False
    stored = dataset.get_attribute(SIGNATURE_ATTR)
    if stored is None:
        return False
    if isinstance(stored, bytes):
        stored = stored.decode("utf-8", errors="replace")
    stored = str(stored)

    canonical = dataset.read_canonical_bytes()

    if stored.startswith(SIGNATURE_V3_PREFIX):
        if algorithm != "ml-dsa-87":
            raise cipher_suite.UnsupportedAlgorithmError(
                f"stored signature is v3 (ml-dsa-87) but caller "
                f"passed algorithm={algorithm!r}"
            )
        cipher_suite.validate_public_key(algorithm, key)
        from . import pqc
        sig = base64.b64decode(stored[len(SIGNATURE_V3_PREFIX):])
        return pqc.sig_verify(key, canonical, sig)

    if algorithm == "ml-dsa-87":
        raise cipher_suite.UnsupportedAlgorithmError(
            "stored signature is not v3 (ml-dsa-87) — pass "
            "algorithm='hmac-sha256' to verify legacy signatures"
        )
    cipher_suite.validate_key(algorithm, key)
    if stored.startswith(SIGNATURE_V2_PREFIX):
        payload = stored[len(SIGNATURE_V2_PREFIX):]
    else:
        payload = stored
    expected = hmac_sha256_b64(canonical, key)
    return hmac.compare_digest(payload, expected)


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
