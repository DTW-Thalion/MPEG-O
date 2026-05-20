"""Workbench client post-quantum protection (ML-KEM-1024 + ML-DSA-87).

A thin client surface over the core :mod:`ttio.pqc` (liboqs) and the
W6.2 :mod:`ttio.workbench.encryption` envelope path. PQC support is
**preview-gated**: every entry point refuses unless the caller opts in
via ``preview=True``, mirroring the server's ``opt_pqc_preview``
feature-flag gating (spec Decision 9).

* **Encapsulation** -- ``seal_pqc`` produces a W6.2 envelope whose DEK is
  wrapped under an ML-KEM-1024 *encapsulation public key* (the recipient
  decapsulates with the matching private key via ``open_pqc``).
* **Signatures** -- optionally sign the sealed ciphertext with ML-DSA-87;
  the signer public key + algorithm land in the ``ProtectionMetadata``,
  the detached signature rides alongside.

Cross-language equivalent: Java
``global.thalion.ttio.workbench.pqc.WorkbenchPqc``. The PQC-envelope
``ProtectionMetadata`` shape (``kek_algorithm="ml-kem-1024"`` /
``signature_algorithm="ml-dsa-87"``) is a cross-language anchor.

API status: Preview (W6.3, behind ``opt_pqc_preview``).
"""
from __future__ import annotations

from dataclasses import dataclass

from .. import pqc as _core_pqc
from ..feature_flags import OPT_PQC_PREVIEW
from ..pqc import KeyPair
from .encryption import (
    ProtectionMetadata,
    ProtectionMode,
    open_sealed,
    seal,
)

ML_KEM_1024 = "ml-kem-1024"
ML_DSA_87 = "ml-dsa-87"


class PQCPreviewDisabledError(RuntimeError):
    """Raised when a PQC entry point is used without opting into the
    preview. Mirrors the server refusing PQC unless ``opt_pqc_preview``
    is set on the stream."""


def _require_preview(preview: bool) -> None:
    if not preview:
        raise PQCPreviewDisabledError(
            f"PQC client support is behind the {OPT_PQC_PREVIEW!r} flag; "
            "pass preview=True to opt in (matches server feature-flag gating)."
        )


def kem_keygen() -> KeyPair:
    """Generate an ML-KEM-1024 encapsulation keypair (passthrough to
    :func:`ttio.pqc.kem_keygen`)."""
    return _core_pqc.kem_keygen()


def sig_keygen() -> KeyPair:
    """Generate an ML-DSA-87 signing keypair (passthrough to
    :func:`ttio.pqc.sig_keygen`)."""
    return _core_pqc.sig_keygen()


@dataclass(frozen=True, slots=True)
class PqcSealed:
    """A PQC-sealed payload: ciphertext + protection descriptor + the
    detached ML-DSA-87 signature (empty when unsigned)."""

    ciphertext: bytes  # iv(12) || tag(16) || ciphertext
    protection: ProtectionMetadata
    signature: bytes


def seal_pqc(
    payload: bytes,
    recipient_kem_public_key: bytes,
    *,
    preview: bool = False,
    signer_private_key: bytes | None = None,
    signer_public_key: bytes | None = None,
) -> PqcSealed:
    """Seal ``payload`` under an ML-KEM-1024 envelope.

    ``recipient_kem_public_key`` is the 1568-byte ML-KEM encapsulation
    public key. If ``signer_private_key`` is given, the sealed ciphertext
    is signed with ML-DSA-87 and the detached signature is returned;
    pass ``signer_public_key`` to record it in the protection metadata.
    """
    _require_preview(preview)
    sealed = seal(payload, mode=ProtectionMode.ENVELOPE,
                  kek=recipient_kem_public_key, kek_algorithm=ML_KEM_1024)
    signature = b""
    signature_algorithm = "none"
    public_key = b""
    if signer_private_key is not None:
        signature = _core_pqc.sig_sign(signer_private_key, sealed.ciphertext)
        signature_algorithm = ML_DSA_87
        public_key = signer_public_key or b""
    meta = ProtectionMetadata(
        cipher_suite=sealed.protection.cipher_suite,
        kek_algorithm=ML_KEM_1024,
        wrapped_dek=sealed.protection.wrapped_dek,
        signature_algorithm=signature_algorithm,
        public_key=public_key,
    )
    return PqcSealed(sealed.ciphertext, meta, signature)


def open_pqc(
    ciphertext: bytes,
    protection: ProtectionMetadata,
    recipient_kem_private_key: bytes,
    *,
    preview: bool = False,
) -> bytes:
    """Decapsulate + decrypt a PQC-sealed payload with the recipient's
    ML-KEM-1024 *private* key (3168 bytes)."""
    _require_preview(preview)
    return open_sealed(ciphertext, protection, kek=recipient_kem_private_key)


def verify_pqc(
    ciphertext: bytes,
    signature: bytes,
    signer_public_key: bytes,
) -> bool:
    """Verify the ML-DSA-87 signature over a PQC-sealed ciphertext."""
    return _core_pqc.sig_verify(signer_public_key, ciphertext, signature)
