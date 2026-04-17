"""AES-256-GCM encryption / decryption matching the ObjC reference layout.

The Objective-C implementation uses OpenSSL ``EVP_aes_256_gcm`` with a
12-byte IV and a 16-byte auth tag. Ciphertext is stored separately from the
tag (via ``EVP_CTRL_GCM_GET_TAG``). Python mirrors this using
``cryptography.hazmat.primitives.ciphers.aead.AESGCM`` — note that
``AESGCM.encrypt`` returns ``ciphertext || tag``; we split the last 16 bytes
off to match the OpenSSL layout.

Per-channel encrypted-signal-channel layout (see §5 of ``docs/format-spec.md``)::

    <channel>_values_encrypted    int32 raw byte container, zero-padded to /4
    <channel>_iv                  3 × int32 raw bytes (12-byte IV)
    <channel>_tag                 4 × int32 raw bytes (16-byte GCM tag)
    @<channel>_ciphertext_bytes   int64  exact ciphertext length
    @<channel>_original_count     int64  original element count
    @<channel>_algorithm          string "AES-256-GCM"

Cross-language equivalents
--------------------------
Objective-C: ``MPGOEncryptionManager`` · Java:
``com.dtwthalion.mpgo.protection.EncryptionManager``.

API status: Stable.
"""
from __future__ import annotations

from dataclasses import dataclass

import h5py
import numpy as np

from . import _hdf5_io as io

AES_KEY_LEN = 32
AES_IV_LEN = 12
AES_TAG_LEN = 16
ALGORITHM_NAME = "AES-256-GCM"


def _aesgcm():  # type: ignore[no-untyped-def]
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "mpeg_o.encryption requires the 'cryptography' optional dependency; "
            "install with 'pip install mpeg-o[crypto]'"
        ) from exc
    return AESGCM


@dataclass(frozen=True, slots=True)
class SealedBlob:
    """Result of an AES-256-GCM encrypt: separate ciphertext, IV, and tag."""

    ciphertext: bytes
    iv: bytes
    tag: bytes


def encrypt_bytes(plaintext: bytes, key: bytes, iv: bytes | None = None) -> SealedBlob:
    """Encrypt ``plaintext`` with AES-256-GCM. Returns ciphertext/iv/tag tuple.

    If ``iv`` is ``None`` a random 12-byte nonce is generated. Tests that need
    cross-implementation parity should pass a fixed ``iv``.
    """
    if len(key) != AES_KEY_LEN:
        raise ValueError(f"AES-256-GCM key must be {AES_KEY_LEN} bytes, got {len(key)}")
    if iv is None:
        import os
        iv = os.urandom(AES_IV_LEN)
    if len(iv) != AES_IV_LEN:
        raise ValueError(f"AES-256-GCM IV must be {AES_IV_LEN} bytes, got {len(iv)}")

    AESGCM = _aesgcm()
    ct_with_tag = AESGCM(key).encrypt(iv, plaintext, associated_data=None)
    ciphertext, tag = ct_with_tag[:-AES_TAG_LEN], ct_with_tag[-AES_TAG_LEN:]
    return SealedBlob(ciphertext=ciphertext, iv=iv, tag=tag)


def decrypt_bytes(blob: SealedBlob, key: bytes) -> bytes:
    """Decrypt an AES-256-GCM sealed blob. Raises on authentication failure."""
    if len(key) != AES_KEY_LEN:
        raise ValueError(f"AES-256-GCM key must be {AES_KEY_LEN} bytes, got {len(key)}")
    if len(blob.iv) != AES_IV_LEN or len(blob.tag) != AES_TAG_LEN:
        raise ValueError("AES-256-GCM IV/tag length mismatch")
    AESGCM = _aesgcm()
    return AESGCM(key).decrypt(blob.iv, blob.ciphertext + blob.tag, associated_data=None)


# ---------------------------------------------- channel-level helpers ---


def read_encrypted_channel(
    channels_group: h5py.Group, channel: str, key: bytes, dtype: str = "<f8"
) -> np.ndarray:
    """Decrypt one encrypted signal channel from a ``signal_channels`` group.

    The plaintext is interpreted as an array of ``dtype`` (default
    little-endian float64, matching the ObjC writer). Raises ``KeyError`` if
    the channel is not encrypted in this group.
    """
    enc_name = f"{channel}_values_encrypted"
    if enc_name not in channels_group:
        raise KeyError(f"channel {channel!r} is not encrypted under this group")

    padded = channels_group[enc_name][()]
    # The ObjC writer packs raw bytes into an int32 dataset. h5py returns a
    # numpy int32 array; take its raw bytes.
    padded_bytes = padded.tobytes()

    ciphertext_bytes = int(io.read_int_attr(
        channels_group, f"{channel}_ciphertext_bytes", default=len(padded_bytes)
    ) or len(padded_bytes))
    ciphertext = padded_bytes[:ciphertext_bytes]

    iv_arr = channels_group[f"{channel}_iv"][()]
    tag_arr = channels_group[f"{channel}_tag"][()]
    iv = iv_arr.tobytes()[:AES_IV_LEN]
    tag = tag_arr.tobytes()[:AES_TAG_LEN]

    plaintext = decrypt_bytes(SealedBlob(ciphertext, iv, tag), key)
    return np.frombuffer(plaintext, dtype=dtype).copy()
