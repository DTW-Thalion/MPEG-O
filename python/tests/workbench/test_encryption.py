"""W6.2 -- workbench client payload protection (BYOK / envelope).

Unit-level byte-equivalence round-trips + the cross-language
ProtectionMetadata JSON anchor (mirrored in the Java
``WorkbenchEncryptionTest``).
"""
import os

import pytest

from ttio.workbench.encryption import (
    ProtectionMetadata,
    ProtectionMode,
    open_sealed,
    seal,
)

# Repo convention: fixed test key is 0x77 * 32 (see
# test_per_au_cross_language.py).
FIXED_DEK = bytes([0x77] * 32)
FIXED_KEK = bytes([0x42] * 32)

# Cross-language anchors -- the Java mirror asserts these exact strings.
BYOK_ANCHOR_JSON = (
    '{"cipher_suite":"aes-256-gcm","kek_algorithm":"none",'
    '"public_key":"","signature_algorithm":"none","wrapped_dek":""}'
)
SIGNED_ANCHOR_JSON = (
    '{"cipher_suite":"aes-256-gcm","kek_algorithm":"none",'
    '"public_key":"AAEC","signature_algorithm":"ml-dsa-87","wrapped_dek":""}'
)


def test_byok_round_trip():
    payload = b"the quick brown fox" * 64
    sealed = seal(payload, mode=ProtectionMode.BYOK, dek=FIXED_DEK)
    assert sealed.ciphertext != payload
    assert sealed.protection.wrapped_dek == b""
    restored = open_sealed(sealed.ciphertext, sealed.protection, dek=FIXED_DEK)
    assert restored == payload


def test_envelope_round_trip():
    payload = os.urandom(4096)
    sealed = seal(payload, mode=ProtectionMode.ENVELOPE, kek=FIXED_KEK)
    assert sealed.protection.wrapped_dek  # non-empty wrapped DEK
    assert sealed.protection.kek_algorithm == "aes-256-gcm"
    restored = open_sealed(sealed.ciphertext, sealed.protection, kek=FIXED_KEK)
    assert restored == payload


def test_byok_wrong_key_fails():
    sealed = seal(b"secret", mode=ProtectionMode.BYOK, dek=FIXED_DEK)
    with pytest.raises(Exception):
        open_sealed(sealed.ciphertext, sealed.protection,
                    dek=bytes([0x00] * 32))


def test_byok_requires_32_byte_dek():
    with pytest.raises(ValueError):
        seal(b"x", mode=ProtectionMode.BYOK, dek=b"short")


def test_envelope_requires_kek():
    with pytest.raises(ValueError):
        seal(b"x", mode=ProtectionMode.ENVELOPE)


def test_byok_payload_needs_dek_to_open():
    sealed = seal(b"x", mode=ProtectionMode.BYOK, dek=FIXED_DEK)
    with pytest.raises(ValueError):
        open_sealed(sealed.ciphertext, sealed.protection)


def test_protection_metadata_json_anchor_byok():
    meta = ProtectionMetadata(
        cipher_suite="aes-256-gcm", kek_algorithm="none",
        wrapped_dek=b"", signature_algorithm="none", public_key=b"")
    assert meta.to_json() == BYOK_ANCHOR_JSON


def test_protection_metadata_json_anchor_signed():
    meta = ProtectionMetadata(
        cipher_suite="aes-256-gcm", kek_algorithm="none",
        wrapped_dek=b"", signature_algorithm="ml-dsa-87",
        public_key=bytes([0, 1, 2]))
    assert meta.to_json() == SIGNED_ANCHOR_JSON


def test_protection_metadata_json_round_trip():
    meta = ProtectionMetadata(
        cipher_suite="aes-256-gcm", kek_algorithm="aes-256-gcm",
        wrapped_dek=os.urandom(71), signature_algorithm="none",
        public_key=os.urandom(32))
    back = ProtectionMetadata.from_json(meta.to_json())
    assert back == meta
