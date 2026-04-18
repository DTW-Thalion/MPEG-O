"""Milestone 25 — envelope encryption + key rotation.

Mirrors the Objective-C ``MPGOKeyRotationManager``. The wrapping
primitive is AES-256-GCM (matching :mod:`mpeg_o.encryption`). A DEK
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
    from mpeg_o.key_rotation import (
        enable_envelope_encryption, rotate_key, unwrap_dek, key_history,
    )

    with h5py.File("x.mpgo", "w") as f:
        kek1 = os.urandom(32)
        dek = enable_envelope_encryption(f, kek1, kek_id="kek-1")
        # ... use dek to encrypt signal ...

    with h5py.File("x.mpgo", "r+") as f:
        kek2 = os.urandom(32)
        rotate_key(f, old_kek=kek1, new_kek=kek2, new_kek_id="kek-2")

    with h5py.File("x.mpgo", "r") as f:
        dek = unwrap_dek(f, kek=kek2)

Cross-language equivalents
--------------------------
Objective-C: ``MPGOKeyRotationManager`` · Java:
``com.dtwthalion.mpgo.protection.KeyRotationManager``.

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
#   +0   2  magic       = 0x4D 0x57 ("MW" — MPGO Wrap)
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


def _key_info_group(f: h5py.File, create: bool = False) -> h5py.Group | None:
    """Return ``/protection/key_info``, creating the path if ``create``."""
    if "protection" not in f:
        if not create:
            return None
        prot = f.create_group("protection")
    else:
        prot = f["protection"]
    if "key_info" not in prot:
        if not create:
            return None
        return prot.create_group("key_info")
    return prot["key_info"]


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


def _unpack_blob(raw: bytes) -> SealedBlob:
    """Dispatch wrapped-key blob parsing on length (v1.1 legacy = 60
    bytes; anything else = v1.2). Returns a SealedBlob suitable for
    :func:`decrypt_bytes`; AES-256-GCM only at this layer."""
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


def _wrap_dek(dek: bytes, kek: bytes, *, legacy_v1: bool = False) -> bytes:
    """Wrap a DEK under a KEK. Default v0.7+ output is v1.2
    (algorithm_id=AES-256-GCM); pass ``legacy_v1=True`` to emit the
    60-byte v1.1 layout for cross-version regression fixtures."""
    if len(dek) != AES_KEY_LEN or len(kek) != AES_KEY_LEN:
        raise KeyRotationError("DEK and KEK must both be 32 bytes")
    blob = encrypt_bytes(dek, kek)
    if legacy_v1:
        return _pack_blob_v1(blob)
    return _pack_blob_v2(
        _WK_ALG_AES_256_GCM,
        ciphertext=bytes(blob.ciphertext),
        metadata=bytes(blob.iv) + bytes(blob.tag),
    )


def _unwrap_dek(wrapped: bytes, kek: bytes) -> bytes:
    if len(kek) != AES_KEY_LEN:
        raise KeyRotationError("KEK must be 32 bytes")
    return decrypt_bytes(_unpack_blob(wrapped), kek)


def _write_wrapped_dataset(ki: h5py.Group, wrapped: bytes) -> None:
    if "dek_wrapped" in ki:
        del ki["dek_wrapped"]
    ki.create_dataset(
        "dek_wrapped",
        data=np.frombuffer(wrapped, dtype="<u1").copy(),
    )


def _read_wrapped_dataset(ki: h5py.Group) -> bytes:
    return bytes(np.asarray(ki["dek_wrapped"][()], dtype="<u1").tobytes())


def _set_string_attr(ki: h5py.Group, name: str, value: str) -> None:
    ki.attrs[name] = np.bytes_(value.encode("utf-8"))


def _get_string_attr(ki: h5py.Group, name: str, default: str = "") -> str:
    if name not in ki.attrs:
        return default
    raw = ki.attrs[name]
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="replace")
    return str(raw)


# ---------------------------------------------------------------- public API


def has_envelope_encryption(f: h5py.File) -> bool:
    """True iff ``/protection/key_info/dek_wrapped`` is present."""
    ki = _key_info_group(f, create=False)
    return ki is not None and "dek_wrapped" in ki


def enable_envelope_encryption(
    f: h5py.File, kek: bytes, *, kek_id: str
) -> bytes:
    """Generate a fresh DEK, wrap it under ``kek``, and persist key_info.

    Returns the plaintext DEK so callers can use it to encrypt signal
    channels. Subsequent reads must unwrap via :func:`unwrap_dek` using
    the same KEK.
    """
    if len(kek) != AES_KEY_LEN:
        raise KeyRotationError(f"KEK must be {AES_KEY_LEN} bytes")
    dek = os.urandom(AES_KEY_LEN)
    wrapped = _wrap_dek(dek, kek)

    ki = _key_info_group(f, create=True)
    assert ki is not None  # create=True guarantees this
    _write_wrapped_dataset(ki, wrapped)
    _set_string_attr(ki, "kek_id", kek_id)
    _set_string_attr(ki, "kek_algorithm", KEK_ALGORITHM)
    _set_string_attr(ki, "wrapped_at", _iso8601_now())
    _set_string_attr(ki, "key_history_json", "[]")
    return dek


def unwrap_dek(f: h5py.File, kek: bytes) -> bytes:
    """Unwrap and return the DEK using the given KEK.

    Raises :class:`KeyRotationError` (or a cryptography ``InvalidTag``)
    when the KEK does not authenticate the wrapped blob.
    """
    ki = _key_info_group(f, create=False)
    if ki is None or "dek_wrapped" not in ki:
        raise KeyRotationError("/protection/key_info/dek_wrapped missing")
    wrapped = _read_wrapped_dataset(ki)
    return _unwrap_dek(wrapped, kek)


def rotate_key(
    f: h5py.File,
    *,
    old_kek: bytes,
    new_kek: bytes,
    new_kek_id: str,
) -> None:
    """Re-wrap the DEK under ``new_kek`` and append the old entry to history.

    Signal datasets are not touched, so the cost is O(1) in file size.
    """
    dek = unwrap_dek(f, old_kek)       # authenticates the old KEK
    wrapped = _wrap_dek(dek, new_kek)

    ki = _key_info_group(f, create=False)
    assert ki is not None              # unwrap_dek already checked

    old_kek_id = _get_string_attr(ki, "kek_id")
    old_wrapped_at = _get_string_attr(ki, "wrapped_at")
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
        "kek_algorithm": KEK_ALGORITHM,
    })

    _write_wrapped_dataset(ki, wrapped)
    _set_string_attr(ki, "kek_id", new_kek_id)
    _set_string_attr(ki, "kek_algorithm", KEK_ALGORITHM)
    _set_string_attr(ki, "wrapped_at", _iso8601_now())
    _set_string_attr(ki, "key_history_json", json.dumps(entries))


def key_history(f: h5py.File) -> list[dict[str, Any]]:
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
