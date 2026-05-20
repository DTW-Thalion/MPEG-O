"""Workbench client-side payload protection (BYOK / envelope).

A thin client wrapper over the core :mod:`ttio.encryption` (AES-256-GCM
bulk seal) and :mod:`ttio.key_rotation` (DEK wrapping) that prepares a
``.tis`` payload for an *encrypted* workbench upload and produces the
matching :class:`ProtectionMetadata` the server records.

Two modes (spec UC-03.2/3):

* **BYOK** -- the researcher brings a 32-byte data-encryption key (DEK).
  The payload is sealed under that DEK; the key never leaves the client,
  so ``wrapped_dek`` is empty. The server stores ciphertext opaquely and
  a future authorised downloader decrypts with the same DEK.
* **ENVELOPE** -- a fresh random DEK seals the payload, and the DEK is
  wrapped under a key-encryption key (KEK) via the core v1.2 wrap
  (AES-256-GCM KEK, or ML-KEM-1024 -- the latter is W6.3/PQC territory).
  ``wrapped_dek`` carries the wrapped key.

Sealed-payload framing (both languages): ``iv(12) || tag(16) ||
ciphertext``. This is the byte string that gets uploaded.

Cross-language equivalent: Java
``global.thalion.ttio.workbench.encryption.WorkbenchEncryptor`` +
``ProtectionMetadata``. The :meth:`ProtectionMetadata.to_json` form is a
cross-language anchor for a fixed BYOK key (deterministic because BYOK
carries no random wrapped DEK).

API status: Preview (W6.2).
"""
from __future__ import annotations

import base64
import enum
import json
import os
from dataclasses import dataclass
from typing import Optional

from ..encryption import AES_IV_LEN, AES_KEY_LEN, AES_TAG_LEN, SealedBlob, \
    decrypt_bytes, encrypt_bytes
from ..key_rotation import _unwrap_dek, _wrap_dek

DEFAULT_CIPHER_SUITE = "aes-256-gcm"
DEFAULT_KEK_ALGORITHM = "aes-256-gcm"


class ProtectionMode(enum.Enum):
    """Client payload-protection mode."""

    BYOK = "byok"
    ENVELOPE = "envelope"


@dataclass(frozen=True, slots=True)
class ProtectionMetadata:
    """Upload-path protection descriptor.

    Mirrors the transport ProtectionMetadata packet
    (``ttio.transport.encrypted``): ``cipher_suite`` / ``kek_algorithm``
    / ``wrapped_dek`` / ``signature_algorithm`` / ``public_key``.
    """

    cipher_suite: str
    kek_algorithm: str
    wrapped_dek: bytes
    signature_algorithm: str
    public_key: bytes

    def to_json(self) -> str:
        """Canonical JSON: sorted keys, compact separators, standard
        base64 for byte blobs. Byte-identical to the Java mirror, so a
        fixed BYOK metadata serialises identically across languages."""
        return json.dumps(
            {
                "cipher_suite": self.cipher_suite,
                "kek_algorithm": self.kek_algorithm,
                "wrapped_dek": base64.b64encode(self.wrapped_dek).decode("ascii"),
                "signature_algorithm": self.signature_algorithm,
                "public_key": base64.b64encode(self.public_key).decode("ascii"),
            },
            sort_keys=True,
            separators=(",", ":"),
        )

    @classmethod
    def from_json(cls, text: str) -> "ProtectionMetadata":
        d = json.loads(text)
        return cls(
            cipher_suite=d["cipher_suite"],
            kek_algorithm=d["kek_algorithm"],
            wrapped_dek=base64.b64decode(d["wrapped_dek"]),
            signature_algorithm=d["signature_algorithm"],
            public_key=base64.b64decode(d["public_key"]),
        )


@dataclass(frozen=True, slots=True)
class SealedPayload:
    """A sealed upload payload plus its protection descriptor."""

    ciphertext: bytes  # iv(12) || tag(16) || ciphertext
    protection: ProtectionMetadata


def _frame(blob: SealedBlob) -> bytes:
    return bytes(blob.iv) + bytes(blob.tag) + bytes(blob.ciphertext)


def _unframe(framed: bytes) -> SealedBlob:
    if len(framed) < AES_IV_LEN + AES_TAG_LEN:
        raise ValueError(
            f"sealed payload too short: {len(framed)} bytes "
            f"(need at least {AES_IV_LEN + AES_TAG_LEN})"
        )
    iv = framed[:AES_IV_LEN]
    tag = framed[AES_IV_LEN:AES_IV_LEN + AES_TAG_LEN]
    ct = framed[AES_IV_LEN + AES_TAG_LEN:]
    return SealedBlob(ciphertext=ct, iv=iv, tag=tag)


def seal(
    payload: bytes,
    *,
    mode: ProtectionMode,
    dek: Optional[bytes] = None,
    kek: Optional[bytes] = None,
    kek_algorithm: str = DEFAULT_KEK_ALGORITHM,
    iv: Optional[bytes] = None,
) -> SealedPayload:
    """Seal ``payload`` for an encrypted upload.

    BYOK: pass the researcher ``dek`` (32 bytes). ENVELOPE: pass a
    ``kek`` (32-byte symmetric for ``aes-256-gcm``, or the ML-KEM-1024
    public key); a fresh DEK is generated and wrapped under it.

    ``iv`` is only for deterministic tests; production uses a random
    nonce per the core seal.
    """
    if mode is ProtectionMode.BYOK:
        if dek is None or len(dek) != AES_KEY_LEN:
            raise ValueError("BYOK requires a 32-byte dek")
        blob = encrypt_bytes(payload, dek, iv)
        meta = ProtectionMetadata(
            cipher_suite=DEFAULT_CIPHER_SUITE,
            kek_algorithm="none",
            wrapped_dek=b"",
            signature_algorithm="none",
            public_key=b"",
        )
        return SealedPayload(_frame(blob), meta)

    if mode is ProtectionMode.ENVELOPE:
        if kek is None:
            raise ValueError("ENVELOPE requires a kek")
        fresh_dek = os.urandom(AES_KEY_LEN)
        blob = encrypt_bytes(payload, fresh_dek, iv)
        wrapped = _wrap_dek(fresh_dek, kek, algorithm=kek_algorithm)
        meta = ProtectionMetadata(
            cipher_suite=DEFAULT_CIPHER_SUITE,
            kek_algorithm=kek_algorithm,
            wrapped_dek=wrapped,
            signature_algorithm="none",
            public_key=b"",
        )
        return SealedPayload(_frame(blob), meta)

    raise ValueError(f"unsupported protection mode: {mode}")


def open_sealed(
    ciphertext: bytes,
    protection: ProtectionMetadata,
    *,
    dek: Optional[bytes] = None,
    kek: Optional[bytes] = None,
) -> bytes:
    """Reverse :func:`seal`. BYOK: pass the same ``dek``. ENVELOPE: pass
    the ``kek`` (32-byte symmetric, or the ML-KEM-1024 private key) used
    to unwrap the DEK."""
    blob = _unframe(ciphertext)
    if protection.wrapped_dek:
        if kek is None:
            raise ValueError("envelope payload requires a kek to unwrap")
        key = _unwrap_dek(protection.wrapped_dek, kek,
                          algorithm=protection.kek_algorithm)
    else:
        if dek is None:
            raise ValueError("BYOK payload requires the dek")
        key = dek
    return decrypt_bytes(blob, key)
