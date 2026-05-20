"""W6.3 -- workbench PQC client (ML-KEM-1024 + ML-DSA-87).

The gating tests run everywhere (they raise before touching liboqs);
the crypto round-trips skip when liboqs is unavailable.
"""
import pytest

from ttio import pqc as core_pqc
from ttio.workbench.encryption import ProtectionMetadata
from ttio.workbench.pqc import (
    PQCPreviewDisabledError,
    open_pqc,
    seal_pqc,
    verify_pqc,
    kem_keygen,
    sig_keygen,
)

requires_pqc = pytest.mark.skipif(
    not core_pqc.is_available(),
    reason="liboqs-python not available",
)

# Cross-language anchor: the PQC-envelope ProtectionMetadata shape
# (deterministic with empty blobs). Mirrored in WorkbenchPqcTest.
PQC_ANCHOR_JSON = (
    '{"cipher_suite":"aes-256-gcm","kek_algorithm":"ml-kem-1024",'
    '"public_key":"","signature_algorithm":"ml-dsa-87","wrapped_dek":""}'
)


def test_seal_refuses_without_preview():
    with pytest.raises(PQCPreviewDisabledError):
        seal_pqc(b"x", b"\x00" * 1568)


def test_open_refuses_without_preview():
    meta = ProtectionMetadata("aes-256-gcm", "ml-kem-1024", b"x",
                              "none", b"")
    with pytest.raises(PQCPreviewDisabledError):
        open_pqc(b"x", meta, b"\x00" * 3168)


def test_pqc_envelope_json_anchor():
    meta = ProtectionMetadata(
        cipher_suite="aes-256-gcm", kek_algorithm="ml-kem-1024",
        wrapped_dek=b"", signature_algorithm="ml-dsa-87", public_key=b"")
    assert meta.to_json() == PQC_ANCHOR_JSON


@requires_pqc
def test_pqc_envelope_round_trip():
    kp = kem_keygen()
    payload = b"post-quantum sealed payload" * 32
    sealed = seal_pqc(payload, kp.public_key, preview=True)
    assert sealed.protection.kek_algorithm == "ml-kem-1024"
    assert sealed.protection.wrapped_dek  # non-empty ML-KEM wrap
    assert sealed.signature == b""  # unsigned
    restored = open_pqc(sealed.ciphertext, sealed.protection,
                        kp.private_key, preview=True)
    assert restored == payload


@requires_pqc
def test_pqc_signed_round_trip():
    kem = kem_keygen()
    sig = sig_keygen()
    payload = b"signed + sealed"
    sealed = seal_pqc(payload, kem.public_key, preview=True,
                      signer_private_key=sig.private_key,
                      signer_public_key=sig.public_key)
    assert sealed.protection.signature_algorithm == "ml-dsa-87"
    assert sealed.protection.public_key == sig.public_key
    assert sealed.signature  # detached signature present
    assert verify_pqc(sealed.ciphertext, sealed.signature, sig.public_key)
    # tamper -> verification fails
    bad = bytearray(sealed.ciphertext)
    bad[-1] ^= 0xFF
    assert not verify_pqc(bytes(bad), sealed.signature, sig.public_key)
    # decapsulation still recovers the payload
    restored = open_pqc(sealed.ciphertext, sealed.protection,
                        kem.private_key, preview=True)
    assert restored == payload


@requires_pqc
def test_pqc_wrong_recipient_key_fails():
    a = kem_keygen()
    b = kem_keygen()
    sealed = seal_pqc(b"secret", a.public_key, preview=True)
    with pytest.raises(Exception):
        open_pqc(sealed.ciphertext, sealed.protection, b.private_key,
                 preview=True)
