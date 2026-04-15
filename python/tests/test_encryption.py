"""Tests for AES-256-GCM encryption parity with the ObjC reference."""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest

from mpeg_o.encryption import (
    AES_IV_LEN,
    AES_KEY_LEN,
    SealedBlob,
    decrypt_bytes,
    encrypt_bytes,
    read_encrypted_channel,
)


# MakeFixtures.m generates both the signing and encryption key via:
#   raw[i] = 0xA5 ^ (i * 3)
FIXTURE_KEY = bytes(0xA5 ^ (i * 3) & 0xFF for i in range(AES_KEY_LEN))


def test_encrypt_then_decrypt_round_trip() -> None:
    key = bytes(range(AES_KEY_LEN))
    plaintext = b"hello, mpeg-o world!" * 32
    blob = encrypt_bytes(plaintext, key)
    assert len(blob.iv) == AES_IV_LEN
    assert len(blob.tag) == 16
    assert len(blob.ciphertext) == len(plaintext)
    assert decrypt_bytes(blob, key) == plaintext


def test_fixed_iv_produces_deterministic_ciphertext() -> None:
    """With a fixed key+iv we can compare ciphertext byte-for-byte across
    implementations — this is how M18/M19 parity tests will be written."""
    key = bytes(range(AES_KEY_LEN))
    iv = bytes(range(AES_IV_LEN))
    a = encrypt_bytes(b"deterministic", key, iv=iv)
    b = encrypt_bytes(b"deterministic", key, iv=iv)
    assert a.ciphertext == b.ciphertext
    assert a.tag == b.tag
    assert a.iv == iv


def test_wrong_key_fails_authentication() -> None:
    key = bytes(range(AES_KEY_LEN))
    wrong = bytes(range(AES_KEY_LEN, 0, -1))
    blob = encrypt_bytes(b"secret", key)
    with pytest.raises(Exception):
        decrypt_bytes(blob, wrong)


def test_key_length_validation() -> None:
    with pytest.raises(ValueError):
        encrypt_bytes(b"x", key=b"short")
    with pytest.raises(ValueError):
        encrypt_bytes(b"x", key=bytes(AES_KEY_LEN), iv=b"short")


def test_decrypt_objc_fixture_intensity_channel(encrypted_fixture: Path) -> None:
    """Cross-implementation parity: a Python reader must decrypt a file
    produced by the ObjC writer using the same key."""
    with h5py.File(encrypted_fixture, "r") as f:
        sig = f["study/ms_runs/run_0001/signal_channels"]
        plaintext = read_encrypted_channel(sig, "intensity", FIXTURE_KEY)
        assert plaintext.dtype == np.float64
        assert plaintext.shape == (80,)  # 10 spectra * 8 points
        assert np.all(plaintext >= 0)
