"""``Verifier`` — high-level sign/verify status wrapper."""
from __future__ import annotations

import base64
import hmac
from enum import IntEnum

from . import signatures


class VerificationStatus(IntEnum):
    """Sign-and-verify cycle outcome.

    Cross-language: ObjC ``TTIOVerificationStatus`` · Java
    ``global.thalion.ttio.protection.Verifier.Status``.
    """

    VALID = 0
    INVALID = 1
    NOT_SIGNED = 2
    ERROR = 3


class Verifier:
    """High-level verification API.

    Collapses the three outcomes of a sign-and-verify cycle
    (valid / invalid / not-signed) into a single enum, plus an error
    fallback for I/O failures. Use this instead of
    :mod:`ttio.signatures` when you want to render a status to an
    end user.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOVerifier`` · Java:
    ``global.thalion.ttio.protection.Verifier``.
    """

    @staticmethod
    def verify(data: bytes, signature: str | None, key: bytes) -> VerificationStatus:
        """Verify a signature string against data and key.

        Parameters
        ----------
        data : bytes
            Original bytes (never ``None``).
        signature : str or None
            Signature string from ``@ttio_signature`` or
            ``@provenance_signature``. ``None`` or empty returns
            :attr:`VerificationStatus.NOT_SIGNED`.
        key : bytes
            32-byte HMAC key.

        Returns
        -------
        VerificationStatus
        """
        if not signature:
            return VerificationStatus.NOT_SIGNED
        try:
            payload = (
                signature[len(signatures.SIGNATURE_V2_PREFIX):]
                if signature.startswith(signatures.SIGNATURE_V2_PREFIX)
                else signature
            )
            expected = signatures.hmac_sha256(data, key)
            actual = base64.b64decode(payload)
            if hmac.compare_digest(expected, actual):
                return VerificationStatus.VALID
            return VerificationStatus.INVALID
        except Exception:
            return VerificationStatus.ERROR
