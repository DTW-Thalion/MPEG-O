"""envelope encryption + key rotation.

Mirrors the Objective-C ``TTIOKeyRotationManager``. The wrapping
primitive is AES-256-GCM (matching :mod:`ttio.encryption`). A DEK
(data-encryption key) encrypts signal payloads; a KEK (key-encryption
key) wraps the DEK. Rotation re-wraps the DEK under a new KEK without
touching any other dataset, so it's O(1) in file size.

On-disk layout under ``/protection/key_info/``:

    @kek_id              (string)   caller-supplied KEK identifier
    @kek_algorithm       (string)   "aes-256-gcm"
    @wrapped_at          (string)   ISO-8601 timestamp
    @key_history_json    (string)   JSON list of prior entries
    dek_wrapped          (uint8[60]) 32 cipher + 12 IV + 16 tag

Usage::

    import h5py, os
    from ttio.key_rotation import (
        enable_envelope_encryption, rotate_key, unwrap_dek, key_history,
    )

    with h5py.File("x.tio", "w") as f:
        kek1 = os.urandom(32)
        dek = enable_envelope_encryption(f, kek1, kek_id="kek-1")
        # ... use dek to encrypt signal ...

    with h5py.File("x.tio", "r+") as f:
        kek2 = os.urandom(32)
        rotate_key(f, old_kek=kek1, new_kek=kek2, new_kek_id="kek-2")

    with h5py.File("x.tio", "r") as f:
        dek = unwrap_dek(f, kek=kek2)

Cross-language equivalents
--------------------------
Objective-C: ``TTIOKeyRotationManager`` · Java:
``global.thalion.ttio.protection.KeyRotationManager``.

API status: Stable.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
from typing import Any

import h5py
import numpy as np

from .encryption import (
    AES_IV_LEN,
    AES_KEY_LEN,
    AES_TAG_LEN,
    SealedBlob,
    decrypt_bytes,
    encrypt_bytes,
)

WRAPPED_BLOB_LEN = AES_KEY_LEN + AES_IV_LEN + AES_TAG_LEN  # 60 (v1.1)
KEK_ALGORITHM = "aes-256-gcm"

# v1.2 wrapped-key blob format (M47, see format-spec §8).
#
# The v1.1 layout was a fixed 60-byte [32 cipher | 12 IV | 16 tag]
# array specific to AES-256-GCM. v1.2 wraps that in a
# versioned, algorithm-discriminated envelope so post-quantum KEMs
# (ML-KEM-1024 ciphertext is 1568 bytes) can ship in the same slot.
#
#   +0   2  magic       = 0x4D 0x57 ("MW" — TTIO Wrap)
#   +2   1  version     = 0x02
#   +3   2  algorithm_id (big-endian)
#               0x0000 = AES-256-GCM
#               0x0001 = ML-KEM-1024  (reserved, M49)
#   +5   4  ciphertext_len (big-endian)
#   +9   2  metadata_len   (big-endian)
#  +11   M  metadata (algorithm-specific: AES-GCM = IV ‖ tag, M=28)
#  +11+M C  ciphertext
#
# Readers dispatch on blob length: exactly 60 bytes ⇒ v1.1 legacy,
# anything else ⇒ v1.2. The magic bytes are an additional integrity
# check once v1.2 is selected; they do NOT disambiguate from v1.1
# because a v1.1 blob that happens to start with 0x4D 0x57 would
# otherwise be misclassified.
_WK_MAGIC = b"MW"
_WK_VERSION_V2 = 0x02
_WK_ALG_AES_256_GCM = 0x0000
_WK_ALG_ML_KEM_1024 = 0x0001  # reserved for M49; emit only behind pqc_preview
_WK_HEADER_LEN = 11  # magic(2) + version(1) + alg(2) + ct_len(4) + md_len(2)


class KeyRotationError(ValueError):
    """Raised when envelope encryption or key rotation fails."""


class UnsupportedWrappedBlobError(KeyRotationError):
    """Raised when a v1.2 wrapped-key blob carries an algorithm id the
    current build cannot unwrap (for example ML-KEM-1024 without the
    ``pqc_preview`` optional install). Always safe to surface to the
    caller — the file itself is not corrupt, it just uses crypto the
    reader doesn't support yet."""


def _iso8601_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _root_group(target: Any):
    """Return a StorageGroup for the rotation target.

    Accepts: ``h5py.File`` (legacy), :class:`StorageProvider`,
    :class:`SpectralDataset` (uses its provider). phase C.
    """
    from .providers.base import StorageGroup, StorageProvider
    from .providers.hdf5 import _Group as _Hdf5Group
    from .spectral_dataset import SpectralDataset
    if isinstance(target, StorageGroup):
        return target
    if isinstance(target, StorageProvider):
        return target.root_group()
    if isinstance(target, SpectralDataset):
        if target.provider is None:
            raise TypeError("SpectralDataset has no attached provider")
        return target.provider.root_group()
    # Assume h5py.File / h5py.Group.
    return _Hdf5Group(target)


def _key_info_group(target: Any, create: bool = False):
    """Return ``/protection/key_info`` as a StorageGroup, creating the
    path if ``create``. Accepts the same target shapes as
    :func:`_root_group`."""
    root = _root_group(target)
    if not root.has_child("protection"):
        if not create:
            return None
        prot = root.create_group("protection")
    else:
        prot = root.open_group("protection")
    if not prot.has_child("key_info"):
        if not create:
            return None
        return prot.create_group("key_info")
    return prot.open_group("key_info")


def _pack_blob_v1(blob: SealedBlob) -> bytes:
    """Pack a SealedBlob into the v1.1 60-byte layout: cipher || iv || tag."""
    if len(blob.ciphertext) != AES_KEY_LEN:
        raise KeyRotationError(
            f"wrapped DEK ciphertext must be {AES_KEY_LEN} bytes "
            f"(got {len(blob.ciphertext)})"
        )
    return bytes(blob.ciphertext) + bytes(blob.iv) + bytes(blob.tag)


def _unpack_blob_v1(raw: bytes) -> SealedBlob:
    if len(raw) != WRAPPED_BLOB_LEN:
        raise KeyRotationError(
            f"v1.1 wrapped DEK blob must be {WRAPPED_BLOB_LEN} bytes "
            f"(got {len(raw)})"
        )
    return SealedBlob(
        ciphertext=raw[:AES_KEY_LEN],
        iv=raw[AES_KEY_LEN:AES_KEY_LEN + AES_IV_LEN],
        tag=raw[AES_KEY_LEN + AES_IV_LEN:],
    )


def _pack_blob_v2(algorithm_id: int, ciphertext: bytes,
                    metadata: bytes) -> bytes:
    """Pack a v1.2 wrapped-key blob (M47).

    Used for AES-256-GCM today (``algorithm_id=0x0000``) and reserved
    for ML-KEM-1024 in M49 (``algorithm_id=0x0001``). See module docstring
    for the byte layout."""
    if len(ciphertext) > 0xFFFF_FFFF:
        raise KeyRotationError("ciphertext exceeds 4 GB")
    if len(metadata) > 0xFFFF:
        raise KeyRotationError("metadata exceeds 64 KB")
    header = (
        _WK_MAGIC
        + bytes([_WK_VERSION_V2])
        + algorithm_id.to_bytes(2, "big")
        + len(ciphertext).to_bytes(4, "big")
        + len(metadata).to_bytes(2, "big")
    )
    assert len(header) == _WK_HEADER_LEN
    return header + metadata + ciphertext


def _unpack_blob_v2(raw: bytes) -> tuple[int, bytes, bytes]:
    """Return ``(algorithm_id, metadata, ciphertext)`` from a v1.2 blob."""
    if len(raw) < _WK_HEADER_LEN:
        raise KeyRotationError(
            f"v1.2 wrapped DEK blob too short ({len(raw)} bytes)"
        )
    if raw[:2] != _WK_MAGIC:
        raise KeyRotationError("v1.2 wrapped DEK blob: bad magic")
    version = raw[2]
    if version != _WK_VERSION_V2:
        raise KeyRotationError(
            f"v1.2 wrapped DEK blob: unknown version 0x{version:02x}"
        )
    algorithm_id = int.from_bytes(raw[3:5], "big")
    ct_len = int.from_bytes(raw[5:9], "big")
    md_len = int.from_bytes(raw[9:11], "big")
    if len(raw) != _WK_HEADER_LEN + md_len + ct_len:
        raise KeyRotationError(
            f"v1.2 wrapped DEK blob length mismatch: header declares "
            f"metadata={md_len} ciphertext={ct_len} "
            f"but blob is {len(raw) - _WK_HEADER_LEN} bytes of payload"
        )
    metadata = raw[_WK_HEADER_LEN:_WK_HEADER_LEN + md_len]
    ciphertext = raw[_WK_HEADER_LEN + md_len:]
    return algorithm_id, metadata, ciphertext


def _unpack_aes_gcm_blob(raw: bytes) -> SealedBlob:
    """Dispatch AES-256-GCM wrapped-key blob parsing on length (v1.1
    legacy = 60 bytes; anything else = v1.2 AES-GCM envelope). Returns
    a SealedBlob suitable for :func:`decrypt_bytes`. Raises
    :class:`UnsupportedWrappedBlobError` if the blob declares a non-AES
    algorithm (the caller should retry via the ML-KEM unwrap path)."""
    if len(raw) == WRAPPED_BLOB_LEN:
        # v1.1 legacy — pre-v0.7 files.
        return _unpack_blob_v1(raw)
    alg, md, ct = _unpack_blob_v2(raw)
    if alg != _WK_ALG_AES_256_GCM:
        raise UnsupportedWrappedBlobError(
            f"v1.2 wrapped-key blob uses algorithm_id=0x{alg:04x} "
            f"which this build does not support (enable 'pqc_preview' "
            f"for ML-KEM-1024 support in M49+)"
        )
    if len(md) != AES_IV_LEN + AES_TAG_LEN:
        raise KeyRotationError(
            f"v1.2 AES-GCM metadata must be {AES_IV_LEN + AES_TAG_LEN} "
            f"bytes (iv || tag); got {len(md)}"
        )
    if len(ct) != AES_KEY_LEN:
        raise KeyRotationError(
            f"v1.2 AES-GCM ciphertext must be {AES_KEY_LEN} bytes; "
            f"got {len(ct)}"
        )
    return SealedBlob(
        ciphertext=ct,
        iv=md[:AES_IV_LEN],
        tag=md[AES_IV_LEN:],
    )


def _unpack_blob(raw: bytes) -> SealedBlob:
    """Legacy alias kept for external callers / tests. Prefer
    :func:`_unpack_aes_gcm_blob` in new code (it names the AES-GCM
    constraint explicitly)."""
    return _unpack_aes_gcm_blob(raw)


# ML-KEM-1024 envelope blob layout (). Inside the v1.2 frame:
#
#   algorithm_id = 0x0001
#   metadata     = kem_ct(1568) || aes_iv(12) || aes_tag(16)     = 1596 bytes
#   ciphertext   = aes_wrapped_dek(32)                            = 32 bytes
#
# Total on-disk payload = 11 (header) + 1596 + 32 = 1639 bytes. The
# receiver decapsulates kem_ct with their ML-KEM private key, uses the
# resulting 32-byte shared secret as the AES-256 KEK, and AES-GCM
# unwraps the DEK.
_MLKEM_CT_LEN = 1568
_MLKEM_METADATA_LEN = _MLKEM_CT_LEN + AES_IV_LEN + AES_TAG_LEN  # 1596


def _pack_ml_kem_blob(
    kem_ct: bytes, aes_iv: bytes, aes_tag: bytes, wrapped_dek: bytes
) -> bytes:
    if len(kem_ct) != _MLKEM_CT_LEN:
        raise KeyRotationError(
            f"ML-KEM-1024 ciphertext must be {_MLKEM_CT_LEN} bytes "
            f"(got {len(kem_ct)})"
        )
    if len(aes_iv) != AES_IV_LEN or len(aes_tag) != AES_TAG_LEN:
        raise KeyRotationError(
            "ML-KEM wrap: AES-GCM metadata has wrong lengths"
        )
    if len(wrapped_dek) != AES_KEY_LEN:
        raise KeyRotationError(
            f"ML-KEM wrap: wrapped DEK must be {AES_KEY_LEN} bytes "
            f"(got {len(wrapped_dek)})"
        )
    return _pack_blob_v2(
        _WK_ALG_ML_KEM_1024,
        ciphertext=wrapped_dek,
        metadata=kem_ct + aes_iv + aes_tag,
    )


def _unpack_ml_kem_blob(raw: bytes) -> tuple[bytes, bytes, bytes, bytes]:
    """Return ``(kem_ct, aes_iv, aes_tag, wrapped_dek)`` from a v1.2
    ML-KEM-1024 envelope blob."""
    alg, md, ct = _unpack_blob_v2(raw)
    if alg != _WK_ALG_ML_KEM_1024:
        raise UnsupportedWrappedBlobError(
            f"expected ML-KEM-1024 algorithm_id=0x0001, got 0x{alg:04x}"
        )
    if len(md) != _MLKEM_METADATA_LEN:
        raise KeyRotationError(
            f"ML-KEM-1024 metadata must be {_MLKEM_METADATA_LEN} bytes "
            f"(kem_ct || iv || tag); got {len(md)}"
        )
    if len(ct) != AES_KEY_LEN:
        raise KeyRotationError(
            f"ML-KEM-1024 wrapped-DEK ciphertext must be {AES_KEY_LEN} "
            f"bytes; got {len(ct)}"
        )
    kem_ct = md[:_MLKEM_CT_LEN]
    aes_iv = md[_MLKEM_CT_LEN:_MLKEM_CT_LEN + AES_IV_LEN]
    aes_tag = md[_MLKEM_CT_LEN + AES_IV_LEN:]
    return kem_ct, aes_iv, aes_tag, ct


def _wrap_dek(
    dek: bytes,
    kek: bytes,
    *,
    legacy_v1: bool = False,
    algorithm: str = "aes-256-gcm",
) -> bytes:
    """Wrap a DEK under a KEK. Default v0.7+ output is v1.2
    (AES-256-GCM); pass ``legacy_v1=True`` to emit the 60-byte v1.1
    layout for cross-version regression fixtures.

    ``algorithm`` selects the wrap primitive. Supported in:

    * ``"aes-256-gcm"`` — ``kek`` is a 32-byte symmetric key.
    * ``"ml-kem-1024"`` — ``kek`` is a 1568-byte ML-KEM encapsulation
      public key. Encapsulation yields a 32-byte shared secret which
      is used as an AES-256 KEK to wrap the DEK.
    """
    from . import cipher_suite
    # The DEK itself is always a symmetric AES-256 key, regardless of
    # the wrap algorithm. HANDOFF binding #43 — AES-256 stays quantum-
    # resistant under Grover.
    cipher_suite.validate_key("aes-256-gcm", dek)

    if algorithm == "aes-256-gcm":
        cipher_suite.validate_key(algorithm, kek)
        blob = encrypt_bytes(dek, kek, algorithm=algorithm)
        if legacy_v1:
            return _pack_blob_v1(blob)
        return _pack_blob_v2(
            _WK_ALG_AES_256_GCM,
            ciphertext=bytes(blob.ciphertext),
            metadata=bytes(blob.iv) + bytes(blob.tag),
        )

    if algorithm == "ml-kem-1024":
        if legacy_v1:
            raise KeyRotationError(
                "v1.1 legacy layout is AES-256-GCM only; "
                "refusing to emit v1.1 for algorithm='ml-kem-1024'"
            )
        cipher_suite.validate_public_key(algorithm, kek)
        from . import pqc
        kem_ct, shared_secret = pqc.kem_encapsulate(kek)
        # shared_secret is 32 bytes (AES-256 width by construction)
        sealed = encrypt_bytes(dek, shared_secret, algorithm="aes-256-gcm")
        return _pack_ml_kem_blob(
            kem_ct=kem_ct,
            aes_iv=bytes(sealed.iv),
            aes_tag=bytes(sealed.tag),
            wrapped_dek=bytes(sealed.ciphertext),
        )

    raise cipher_suite.UnsupportedAlgorithmError(
        f"{algorithm!r}: wrap path not implemented"
    )


def _unwrap_dek(
    wrapped: bytes,
    kek: bytes,
    *,
    algorithm: str = "aes-256-gcm",
) -> bytes:
    from . import cipher_suite

    if algorithm == "aes-256-gcm":
        cipher_suite.validate_key(algorithm, kek)
        return decrypt_bytes(
            _unpack_aes_gcm_blob(wrapped), kek, algorithm=algorithm
        )

    if algorithm == "ml-kem-1024":
        cipher_suite.validate_private_key(algorithm, kek)
        from . import pqc
        kem_ct, aes_iv, aes_tag, wrapped_dek = _unpack_ml_kem_blob(wrapped)
        shared_secret = pqc.kem_decapsulate(kek, kem_ct)
        sealed = SealedBlob(ciphertext=wrapped_dek, iv=aes_iv, tag=aes_tag)
        return decrypt_bytes(sealed, shared_secret, algorithm="aes-256-gcm")

    raise cipher_suite.UnsupportedAlgorithmError(
        f"{algorithm!r}: unwrap path not implemented"
    )


def _native_h5_from(ki):
    """Extract the underlying h5py.Group if ``ki`` is h5py-backed.

    Accepts raw h5py.Group (returns it directly) or an HDF5-backed
    StorageGroup (unwraps via the ``_grp`` attribute). Returns
    ``None`` for non-HDF5 StorageGroup inputs so callers dispatch
    onto the protocol path.
    """
    from .providers.base import StorageGroup
    if isinstance(ki, StorageGroup):
        return getattr(ki, "_grp", None)
    # Assume raw h5py object.
    return ki


def _write_wrapped_dataset(ki, wrapped: bytes) -> None:
    """Write the wrapped DEK blob.

    HDF5 fast path keeps the legacy uint8 layout for byte parity
    with ObjC / Java readers and pre-M64.5 files. Non-HDF5 providers
    pack the bytes into a UINT32 array because the storage protocol
    has no UINT8 precision (the byte length is preserved verbatim;
    only the on-disk dtype differs across backends).
    """
    from .enums import Precision
    native = _native_h5_from(ki)
    if native is not None:
        if "dek_wrapped" in native:
            del native["dek_wrapped"]
        native.create_dataset(
            "dek_wrapped",
            data=np.frombuffer(wrapped, dtype="<u1").copy(),
        )
        return
    # Storage-protocol path: pack into UINT32 (pad to multiple of 4).
    if ki.has_child("dek_wrapped"):
        ki.delete_child("dek_wrapped")
    pad = (-len(wrapped)) % 4
    blob = wrapped + b"\x00" * pad
    arr = np.frombuffer(blob, dtype="<u4").copy()
    ds = ki.create_dataset("dek_wrapped", Precision.UINT32, arr.size)
    ds.write(arr)
    ki.set_attribute("dek_wrapped_byte_length", int(len(wrapped)))


def _read_wrapped_dataset(ki) -> bytes:
    native = _native_h5_from(ki)
    if native is not None:
        return bytes(np.asarray(native["dek_wrapped"][()], dtype="<u1").tobytes())
    arr = np.asarray(ki.open_dataset("dek_wrapped").read())
    raw = arr.tobytes()
    if ki.has_attribute("dek_wrapped_byte_length"):
        n = int(ki.get_attribute("dek_wrapped_byte_length"))
        return raw[:n]
    return raw


def _set_string_attr(ki, name: str, value: str) -> None:
    native = _native_h5_from(ki)
    if native is not None:
        native.attrs[name] = np.bytes_(value.encode("utf-8"))
        return
    ki.set_attribute(name, value)


def _get_string_attr(ki, name: str, default: str = "") -> str:
    native = _native_h5_from(ki)
    if native is not None:
        if name not in native.attrs:
            return default
        raw = native.attrs[name]
    else:
        if not ki.has_attribute(name):
            return default
        raw = ki.get_attribute(name)
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="replace")
    return str(raw)


# ---------------------------------------------------------------- public API


def has_envelope_encryption(f: Any) -> bool:
    """True iff ``/protection/key_info/dek_wrapped`` is present.

    phase C: ``f`` may be ``h5py.File``, a
    :class:`StorageProvider`, or a :class:`SpectralDataset`.
    """
    ki = _key_info_group(f, create=False)
    if ki is None:
        return False
    native = _native_h5_from(ki)
    if native is not None:
        return "dek_wrapped" in native
    return ki.has_child("dek_wrapped")


def _validate_kek_for_wrap(algorithm: str, kek: bytes) -> None:
    """Validate ``kek`` for use as a *writer-side* KEK under ``algorithm``
    (AES symmetric key for AES-GCM, ML-KEM public key for ML-KEM-1024)."""
    from . import cipher_suite
    if algorithm == "aes-256-gcm":
        cipher_suite.validate_key(algorithm, kek)
    elif algorithm == "ml-kem-1024":
        cipher_suite.validate_public_key(algorithm, kek)
    else:
        raise cipher_suite.UnsupportedAlgorithmError(
            f"{algorithm!r}: wrap path not implemented"
        )


def _validate_kek_for_unwrap(algorithm: str, kek: bytes) -> None:
    """Validate ``kek`` for use as a *reader-side* KEK under ``algorithm``."""
    from . import cipher_suite
    if algorithm == "aes-256-gcm":
        cipher_suite.validate_key(algorithm, kek)
    elif algorithm == "ml-kem-1024":
        cipher_suite.validate_private_key(algorithm, kek)
    else:
        raise cipher_suite.UnsupportedAlgorithmError(
            f"{algorithm!r}: unwrap path not implemented"
        )


def _mark_pqc_preview(f: Any) -> None:
    """Append ``opt_pqc_preview`` to the root ``@ttio_features`` list
    if it's not already present. No-op on files without the feature
    index (pre-v0.2 layout)."""
    from .feature_flags import OPT_PQC_PREVIEW
    root = _root_group(f)
    native = _native_h5_from(root)
    if native is not None:
        if "ttio_features" not in native.attrs:
            return
        raw = native.attrs["ttio_features"]
    else:
        if not root.has_attribute("ttio_features"):
            return
        raw = root.get_attribute("ttio_features")
    if isinstance(raw, bytes):
        decoded = raw.decode("utf-8", errors="replace")
    else:
        decoded = str(raw)
    try:
        features = json.loads(decoded)
        if not isinstance(features, list):
            features = []
    except json.JSONDecodeError:
        features = []
    if OPT_PQC_PREVIEW in features:
        return
    features.append(OPT_PQC_PREVIEW)
    if native is not None:
        native.attrs["ttio_features"] = json.dumps(features)
    else:
        root.set_attribute("ttio_features", json.dumps(features))


def enable_envelope_encryption(
    f: Any,
    kek: bytes,
    *,
    kek_id: str,
    algorithm: str = "aes-256-gcm",
) -> bytes:
    """Generate a fresh DEK, wrap it under ``kek``, and persist key_info.

    Returns the plaintext DEK so callers can use it to encrypt signal
    channels. Subsequent reads must unwrap via :func:`unwrap_dek` using
    the same KEK shape.

    ``algorithm`` selects the wrap cipher suite:

    * ``"aes-256-gcm"`` — ``kek`` is a 32-byte symmetric key.
    * ``"ml-kem-1024"`` — ``kek`` is a 1568-byte ML-KEM *public* key.
      This writes the ``opt_pqc_preview`` feature flag onto the file
      ().
    """
    _validate_kek_for_wrap(algorithm, kek)
    dek = os.urandom(AES_KEY_LEN)
    wrapped = _wrap_dek(dek, kek, algorithm=algorithm)

    ki = _key_info_group(f, create=True)
    assert ki is not None  # create=True guarantees this
    _write_wrapped_dataset(ki, wrapped)
    _set_string_attr(ki, "kek_id", kek_id)
    _set_string_attr(ki, "kek_algorithm", algorithm)
    _set_string_attr(ki, "wrapped_at", _iso8601_now())
    _set_string_attr(ki, "key_history_json", "[]")
    if algorithm == "ml-kem-1024":
        _mark_pqc_preview(f)
    return dek


def unwrap_dek(
    f: Any,
    kek: bytes,
    *,
    algorithm: str = "aes-256-gcm",
) -> bytes:
    """Unwrap and return the DEK using the given KEK.

    Raises :class:`KeyRotationError` (or a cryptography ``InvalidTag``)
    when the KEK does not authenticate the wrapped blob. For
    ``algorithm="ml-kem-1024"`` pass the 3168-byte decapsulation
    *private* key.
    """
    _validate_kek_for_unwrap(algorithm, kek)
    ki = _key_info_group(f, create=False)
    if ki is None:
        raise KeyRotationError("/protection/key_info/dek_wrapped missing")
    native = _native_h5_from(ki)
    has = ("dek_wrapped" in native) if native is not None else ki.has_child("dek_wrapped")
    if not has:
        raise KeyRotationError("/protection/key_info/dek_wrapped missing")
    wrapped = _read_wrapped_dataset(ki)
    return _unwrap_dek(wrapped, kek, algorithm=algorithm)


def rotate_key(
    f: Any,
    *,
    old_kek: bytes,
    new_kek: bytes,
    new_kek_id: str,
    algorithm: str = "aes-256-gcm",
    new_algorithm: str | None = None,
) -> None:
    """Re-wrap the DEK under ``new_kek`` and append the old entry to history.

    Signal datasets are not touched, so the cost is O(1) in file size.

    : ``new_algorithm`` may differ from ``algorithm`` to migrate
    a file from classical AES-256-GCM to ML-KEM-1024 (or back). When
    ``new_algorithm`` is omitted, the wrap stays on the same primitive.
    """
    if new_algorithm is None:
        new_algorithm = algorithm
    dek = unwrap_dek(f, old_kek, algorithm=algorithm)       # authenticates the old KEK
    _validate_kek_for_wrap(new_algorithm, new_kek)
    wrapped = _wrap_dek(dek, new_kek, algorithm=new_algorithm)

    ki = _key_info_group(f, create=False)
    assert ki is not None              # unwrap_dek already checked

    old_kek_id = _get_string_attr(ki, "kek_id")
    old_wrapped_at = _get_string_attr(ki, "wrapped_at")
    old_algorithm = _get_string_attr(ki, "kek_algorithm", algorithm)
    history_json = _get_string_attr(ki, "key_history_json", "[]")
    try:
        entries = json.loads(history_json)
        if not isinstance(entries, list):
            entries = []
    except json.JSONDecodeError:
        entries = []
    entries.append({
        "timestamp": old_wrapped_at,
        "kek_id": old_kek_id,
        "kek_algorithm": old_algorithm,
    })

    _write_wrapped_dataset(ki, wrapped)
    _set_string_attr(ki, "kek_id", new_kek_id)
    _set_string_attr(ki, "kek_algorithm", new_algorithm)
    _set_string_attr(ki, "wrapped_at", _iso8601_now())
    _set_string_attr(ki, "key_history_json", json.dumps(entries))
    if new_algorithm == "ml-kem-1024":
        _mark_pqc_preview(f)


def key_history(f: Any) -> list[dict[str, Any]]:
    """Return the list of prior (timestamp, kek_id, kek_algorithm) entries."""
    ki = _key_info_group(f, create=False)
    if ki is None:
        return []
    raw = _get_string_attr(ki, "key_history_json", "[]")
    try:
        entries = json.loads(raw)
    except json.JSONDecodeError:
        return []
    return entries if isinstance(entries, list) else []
