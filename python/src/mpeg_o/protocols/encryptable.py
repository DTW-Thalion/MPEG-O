"""``Encryptable`` — multi-level content protection capability."""
from __future__ import annotations

from typing import Protocol, runtime_checkable

from ..enums import EncryptionLevel


@runtime_checkable
class Encryptable(Protocol):
    """Capability for MPEG-G-style multi-level content protection.

    Encryption can be applied at dataset-group, dataset,
    descriptor-stream, or access-unit granularity, enabling selective
    protection (for example, encrypting intensity values while leaving
    m/z and scan metadata readable for indexing and search).

    Methods
    -------
    encrypt_with_key(key, level)
        Encrypt this object's protectable content at the given
        granularity.
    decrypt_with_key(key)
        Decrypt previously-encrypted content.
    access_policy()
        Return the current access policy.
    set_access_policy(policy)
        Replace the current access policy.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOEncryptable`` ·
    Java: ``com.dtwthalion.mpgo.protocols.Encryptable``
    """

    def encrypt_with_key(self, key: bytes, level: EncryptionLevel) -> None: ...
    def decrypt_with_key(self, key: bytes) -> None: ...
    def access_policy(self) -> "object | None": ...
    def set_access_policy(self, policy: "object | None") -> None: ...
