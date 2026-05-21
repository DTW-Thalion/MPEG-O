"""Workbench client post-quantum protection (ML-KEM-1024).

A thin client surface over the core :mod:`ttio.pqc` (liboqs). PQC support
is **preview-gated**: every entry point refuses unless the caller opts in
via ``preview=True``, mirroring the server's ``opt_pqc_preview``
feature-flag gating (spec Decision 9).

The per-AU encrypted-upload path (``WorkbenchClient.upload_encrypted_pqc``
/ ``download_decrypted_pqc``) wraps a per-run DEK under an ML-KEM-1024
encapsulation public key and carries it in the transport
``ProtectionMetadata`` packet. This module supplies the keypair generator
and the preview gate that path uses; the wrap/unwrap itself lives in
:mod:`ttio.key_rotation` (``_wrap_dek`` / ``_unwrap_dek``).

Cross-language equivalent: Java
``global.thalion.ttio.workbench.pqc.WorkbenchPqc``.

API status: Preview (W6.3, behind ``opt_pqc_preview``).
"""
from __future__ import annotations

from .. import pqc as _core_pqc
from ..feature_flags import OPT_PQC_PREVIEW
from ..pqc import KeyPair

ML_KEM_1024 = "ml-kem-1024"


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
