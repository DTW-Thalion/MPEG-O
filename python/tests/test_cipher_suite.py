"""CipherSuite catalog tests (v0.7 M48).

The catalog is a static allow-list. These tests pin the invariants:
every active algorithm has sensible metadata; reserved algorithms
fail cleanly; key / nonce / tag lengths dispatch correctly.
"""
from __future__ import annotations

import pytest

from mpeg_o import cipher_suite
from mpeg_o.cipher_suite import (
    InvalidKeyError,
    UnsupportedAlgorithmError,
)


# ── Catalog shape ────────────────────────────────────────────────────


def test_active_defaults_are_registered():
    for alg in ("aes-256-gcm", "hmac-sha256", "sha-256"):
        assert cipher_suite.is_supported(alg)
        assert cipher_suite.is_registered(alg)


def test_reserved_entries_registered_but_not_supported():
    for alg in ("ml-kem-1024", "ml-dsa-87", "shake256"):
        assert cipher_suite.is_registered(alg), f"{alg} should be in the catalog"
        assert not cipher_suite.is_supported(alg), (
            f"{alg} must report NOT supported until M49 activates it"
        )


def test_unknown_algorithm_is_neither_registered_nor_supported():
    for alg in ("aes-128-gcm", "chacha20-poly1305", "garbage"):
        assert not cipher_suite.is_registered(alg)
        assert not cipher_suite.is_supported(alg)


def test_algorithms_filter_by_status():
    active = cipher_suite.algorithms(status="active")
    reserved = cipher_suite.algorithms(status="reserved")
    assert "aes-256-gcm" in active
    assert "ml-kem-1024" in reserved
    assert set(active).isdisjoint(reserved)
    assert set(cipher_suite.algorithms()) == set(active) | set(reserved)


# ── Metadata lookups ─────────────────────────────────────────────────


def test_aes_256_gcm_metadata():
    assert cipher_suite.category("aes-256-gcm") == "AEAD"
    assert cipher_suite.key_length("aes-256-gcm") == 32
    assert cipher_suite.nonce_length("aes-256-gcm") == 12
    assert cipher_suite.tag_length("aes-256-gcm") == 16


def test_hmac_sha256_metadata():
    assert cipher_suite.category("hmac-sha256") == "MAC"
    assert cipher_suite.key_length("hmac-sha256") is None  # variable
    assert cipher_suite.nonce_length("hmac-sha256") == 0
    assert cipher_suite.tag_length("hmac-sha256") == 32


def test_ml_kem_1024_metadata_even_though_reserved():
    # Metadata queries succeed even on reserved entries; only
    # validate_key rejects them with UnsupportedAlgorithmError.
    assert cipher_suite.category("ml-kem-1024") == "KEM"
    assert cipher_suite.key_length("ml-kem-1024") == 1568
    assert cipher_suite.nonce_length("ml-kem-1024") == 0


def test_unknown_algorithm_metadata_raises():
    with pytest.raises(UnsupportedAlgorithmError, match="unknown algorithm"):
        cipher_suite.nonce_length("not-a-real-algorithm")


# ── validate_key dispatch ───────────────────────────────────────────


def test_validate_key_aes_256_gcm_accepts_32_bytes():
    cipher_suite.validate_key("aes-256-gcm", b"\x00" * 32)


@pytest.mark.parametrize("wrong_len", [0, 1, 16, 31, 33, 64])
def test_validate_key_aes_256_gcm_rejects_wrong_length(wrong_len: int):
    with pytest.raises(InvalidKeyError, match="32 bytes"):
        cipher_suite.validate_key("aes-256-gcm", b"\x00" * wrong_len)


def test_validate_key_hmac_sha256_accepts_any_nonempty_key():
    cipher_suite.validate_key("hmac-sha256", b"k")
    cipher_suite.validate_key("hmac-sha256", b"\x00" * 32)
    cipher_suite.validate_key("hmac-sha256", b"x" * 100)


def test_validate_key_hmac_sha256_rejects_empty_key():
    with pytest.raises(InvalidKeyError, match="non-empty"):
        cipher_suite.validate_key("hmac-sha256", b"")


def test_validate_key_reserved_algorithm_raises():
    with pytest.raises(UnsupportedAlgorithmError, match="reserved"):
        cipher_suite.validate_key("ml-kem-1024", b"\x00" * 1568)


def test_validate_key_unknown_algorithm_raises():
    with pytest.raises(UnsupportedAlgorithmError, match="unknown"):
        cipher_suite.validate_key("garbage", b"\x00" * 32)


# ── Integration: threads through to encrypt_bytes / sign_dataset ────


def test_encrypt_bytes_default_algorithm_unchanged():
    """Default path must be byte-identical to pre-M48."""
    from mpeg_o.encryption import encrypt_bytes, decrypt_bytes
    key = b"k" * 32
    iv = b"i" * 12
    blob = encrypt_bytes(b"hello", key, iv)
    assert len(blob.iv) == 12
    assert len(blob.tag) == 16
    assert decrypt_bytes(blob, key) == b"hello"


def test_encrypt_bytes_explicit_algorithm_parameter():
    from mpeg_o.encryption import encrypt_bytes, decrypt_bytes
    key = b"k" * 32
    iv = b"i" * 12
    blob = encrypt_bytes(b"hello", key, iv, algorithm="aes-256-gcm")
    assert decrypt_bytes(blob, key, algorithm="aes-256-gcm") == b"hello"


def test_encrypt_bytes_rejects_unknown_algorithm():
    from mpeg_o.encryption import encrypt_bytes
    key = b"k" * 32
    with pytest.raises(UnsupportedAlgorithmError):
        encrypt_bytes(b"hello", key, algorithm="chacha20-poly1305")


def test_encrypt_bytes_rejects_reserved_algorithm():
    """ml-kem-1024 is catalog-registered but has status reserved
    until M49 activates it."""
    from mpeg_o.encryption import encrypt_bytes
    with pytest.raises(UnsupportedAlgorithmError, match="reserved"):
        encrypt_bytes(b"hello", b"k" * 1568, algorithm="ml-kem-1024")


def test_sign_dataset_rejects_reserved_signature_algorithm(tmp_path):
    """Passing ``algorithm="ml-dsa-87"`` must fail cleanly pre-M49."""
    import h5py
    import numpy as np
    from mpeg_o.signatures import sign_dataset

    path = tmp_path / "m48_sig_algo.mpgo"
    with h5py.File(path, "w") as f:
        ds = f.create_dataset("v", data=np.arange(4, dtype="<f8"))
        with pytest.raises(UnsupportedAlgorithmError, match="reserved"):
            sign_dataset(ds, b"k" * 32, algorithm="ml-dsa-87")
