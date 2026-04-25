"""Post-quantum crypto primitives — ML-KEM-1024 + ML-DSA-87 (v0.8 M49).

Thin wrapper over ``liboqs-python`` (Open Quantum Safe) that gives the
rest of :mod:`ttio` a stable surface for FIPS 203 (ML-KEM-1024) key
encapsulation and FIPS 204 (ML-DSA-87) digital signatures without
leaking the ``oqs`` API directly.

Availability
------------
This module requires the ``[pqc]`` extra:

.. code-block:: bash

    pip install 'ttio[pqc]'

which pulls in ``liboqs-python`` (pure Python over ``ctypes``). The
wrapper in turn needs a system ``liboqs`` ≥ 0.14 shared library.
``liboqs-python`` auto-installs one to ``$HOME/_oqs`` on first import
if missing, but CI is expected to provide it explicitly (Ubuntu 24.04
has no apt package). See :file:`docs/pqc.md` for the platform matrix.

If ``oqs`` is not importable, every entry point in this module raises
:class:`PQCUnavailableError` at call time — importing :mod:`ttio.pqc`
itself succeeds so that the rest of the package stays importable on
hosts without liboqs.

Role map
--------
* **Encapsulation** (sender, writer side) takes a *public key* and
  returns ``(kem_ciphertext, shared_secret)``.
* **Decapsulation** (receiver, reader side) takes a *private key* and
  the KEM ciphertext, returns ``shared_secret``.
* **Sign** takes a *signing key* (private) and message, returns
  ``signature``.
* **Verify** takes a *verification key* (public), message, and
  signature, returns ``bool``.

All public-key / private-key / ciphertext / signature sizes are pinned
by FIPS 203 and FIPS 204; see :mod:`ttio.cipher_suite` for the
catalog values.

Cross-language equivalents
--------------------------
* Objective-C: ``TTIOCipherSuite`` (same liboqs library, C API)
* Java: Bouncy Castle ``org.bouncycastle.pqc.*`` (different provider
  — see :file:`docs/pqc.md` § "Why Python/ObjC use liboqs but Java
  uses Bouncy Castle").

API status: Provisional (v0.8). Subject to breaking changes through
the v0.8 series; will be marked Stable at v1.0.
"""
from __future__ import annotations

from dataclasses import dataclass

__all__ = [
    "PQCUnavailableError",
    "ML_KEM_1024",
    "ML_DSA_87",
    "is_available",
    "kem_keygen",
    "kem_encapsulate",
    "kem_decapsulate",
    "sig_keygen",
    "sig_sign",
    "sig_verify",
]


ML_KEM_1024 = "ML-KEM-1024"
ML_DSA_87 = "ML-DSA-87"


class PQCUnavailableError(RuntimeError):
    """Raised when a PQC primitive is requested but the optional
    ``liboqs-python`` / system ``liboqs`` dependency is missing.

    Swallow at the call site to provide a graceful "PQC unavailable"
    experience (for example when a reader opens a v3: signed file
    without the ``[pqc]`` extra installed).
    """


@dataclass(frozen=True, slots=True)
class KeyPair:
    public_key: bytes
    private_key: bytes


def _oqs():  # type: ignore[no-untyped-def]
    try:
        import oqs  # type: ignore[import-not-found]
    except ImportError as exc:  # pragma: no cover - exercised indirectly
        raise PQCUnavailableError(
            "ttio.pqc requires the optional 'liboqs-python' dependency — "
            "install with: pip install 'ttio[pqc]'"
        ) from exc
    return oqs


def is_available() -> bool:
    """Return True iff liboqs-python is importable. Does not touch the
    native library, so it's cheap to call repeatedly."""
    try:
        _oqs()
    except PQCUnavailableError:
        return False
    return True


# --------------------------------------------------- ML-KEM-1024 (FIPS 203) ---


def kem_keygen(algorithm: str = ML_KEM_1024) -> KeyPair:
    """Generate a new ML-KEM-1024 encapsulation keypair.

    Returns a :class:`KeyPair` of raw bytes. For ML-KEM-1024:
    ``len(public_key) == 1568``, ``len(private_key) == 3168``.
    """
    oqs = _oqs()
    with oqs.KeyEncapsulation(algorithm) as kem:
        pk = bytes(kem.generate_keypair())
        sk = bytes(kem.export_secret_key())
    return KeyPair(public_key=pk, private_key=sk)


def kem_encapsulate(
    public_key: bytes, algorithm: str = ML_KEM_1024
) -> tuple[bytes, bytes]:
    """Encapsulate a fresh shared secret under ``public_key``.

    Returns ``(kem_ciphertext, shared_secret)``. For ML-KEM-1024 the
    ciphertext is 1568 bytes and the shared secret is 32 bytes (the
    natural width of an AES-256 key — used downstream to AES-wrap the
    actual DEK in the envelope model).
    """
    oqs = _oqs()
    with oqs.KeyEncapsulation(algorithm) as kem:
        ct, ss = kem.encap_secret(public_key)
    return bytes(ct), bytes(ss)


def kem_decapsulate(
    private_key: bytes, ciphertext: bytes, algorithm: str = ML_KEM_1024
) -> bytes:
    """Recover the shared secret from a KEM ciphertext using ``private_key``.

    Returns 32 bytes for ML-KEM-1024. Raises the underlying ``oqs``
    exception on malformed inputs — ML-KEM does not have
    authenticated decapsulation, so a corrupted ciphertext yields a
    well-formed but meaningless shared secret; downstream AES-GCM
    unwrap authenticates the chain.
    """
    oqs = _oqs()
    with oqs.KeyEncapsulation(algorithm, secret_key=private_key) as kem:
        return bytes(kem.decap_secret(ciphertext))


# --------------------------------------------------- ML-DSA-87 (FIPS 204) ---


def sig_keygen(algorithm: str = ML_DSA_87) -> KeyPair:
    """Generate a new ML-DSA-87 signing keypair.

    For ML-DSA-87: ``len(public_key) == 2592``, ``len(private_key) == 4896``.
    """
    oqs = _oqs()
    with oqs.Signature(algorithm) as signer:
        pk = bytes(signer.generate_keypair())
        sk = bytes(signer.export_secret_key())
    return KeyPair(public_key=pk, private_key=sk)


def sig_sign(
    private_key: bytes, message: bytes, algorithm: str = ML_DSA_87
) -> bytes:
    """Sign ``message`` with the given ML-DSA-87 signing key. Returns
    raw signature bytes (4627 bytes for ML-DSA-87)."""
    oqs = _oqs()
    with oqs.Signature(algorithm, secret_key=private_key) as signer:
        return bytes(signer.sign(message))


def sig_verify(
    public_key: bytes,
    message: bytes,
    signature: bytes,
    algorithm: str = ML_DSA_87,
) -> bool:
    """Verify that ``signature`` is a valid ML-DSA-87 signature on
    ``message`` under ``public_key``. Returns ``True`` / ``False``;
    malformed inputs surface as the underlying ``oqs`` exception so
    callers can distinguish "wrong signature" from "corrupt file"."""
    oqs = _oqs()
    with oqs.Signature(algorithm) as verifier:
        return bool(verifier.verify(message, signature, public_key))
