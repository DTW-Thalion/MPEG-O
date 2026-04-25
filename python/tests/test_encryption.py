"""Tests for AES-256-GCM encryption parity with the ObjC reference."""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio.encryption import (
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
    plaintext = b"hello, ttio world!" * 32
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


# ------------------------------------------------------------------ helpers


def _make_ttio_fixture(path, run_names: list) -> None:
    """Write a minimal valid .tio file with float64 intensity_values."""
    with h5py.File(path, "w") as f:
        f.attrs["ttio_format_version"] = "0.6"
        study = f.create_group("study")
        runs_group = study.create_group("ms_runs")
        runs_group.attrs["_run_names"] = ",".join(run_names)
        from ttio.enums import AcquisitionMode
        for rname in run_names:
            g = runs_group.create_group(rname)
            g.attrs["acquisition_mode"] = np.int64(AcquisitionMode.MS1_DDA)
            g.attrs["spectrum_class"] = "TTIOMassSpectrum"
            idx = g.create_group("spectrum_index")
            idx.create_dataset("offsets", data=np.array([0], dtype="<u8"))
            idx.create_dataset("lengths", data=np.array([4], dtype="<u4"))
            idx.create_dataset("retention_times", data=np.array([0.0], dtype="<f8"))
            idx.create_dataset("ms_levels", data=np.array([1], dtype="<i4"))
            idx.create_dataset("polarities", data=np.array([1], dtype="<i4"))
            idx.create_dataset("precursor_mzs", data=np.array([0.0], dtype="<f8"))
            idx.create_dataset("precursor_charges", data=np.array([0], dtype="<i4"))
            idx.create_dataset("base_peak_intensities", data=np.array([0.0], dtype="<f8"))
            sc = g.create_group("signal_channels")
            sc.attrs["channel_names"] = "mz,intensity"
            sc.create_dataset(
                "mz_values",
                data=np.array([100.0, 200.0, 300.0, 400.0], dtype="<f8"),
            )
            sc.create_dataset(
                "intensity_values",
                data=np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8"),
            )


# ------------------------------------------------------------------ new tests


def test_acquisition_run_encrypt_decrypt_round_trip(tmp_path):
    """Full round-trip: open dataset, encrypt via run.encrypt_with_key,
    re-open, decrypt via run.decrypt_with_key, verify plaintext matches."""
    from ttio import SpectralDataset
    from ttio.enums import EncryptionLevel

    path = str(tmp_path / "encryptable.tio")
    key = bytes(range(32))  # 32-byte AES-256 key
    original_intensity = np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")

    _make_ttio_fixture(path, ["run_0001"])

    # Encrypt via run.encrypt_with_key (open writable so h5py allows writes)
    ds = SpectralDataset.open(path, writable=True)
    run = ds.ms_runs["run_0001"]
    run.encrypt_with_key(key, EncryptionLevel.DATASET)
    ds.close()

    # Verify on-disk layout: encrypted datasets present, plaintext gone
    with h5py.File(path, "r") as f:
        sc = f["study/ms_runs/run_0001/signal_channels"]
        assert "intensity_values_encrypted" in sc, "encrypted dataset missing"
        assert "intensity_values" not in sc, "plaintext dataset should be removed"
        assert "intensity_iv" in sc, "IV dataset missing"
        assert "intensity_tag" in sc, "tag dataset missing"
        assert "intensity_ciphertext_bytes" in sc.attrs
        assert "intensity_original_count" in sc.attrs
        assert sc.attrs["intensity_algorithm"] == "AES-256-GCM"

    # Idempotency: a second encrypt_with_key on the same file must not raise
    ds = SpectralDataset.open(path, writable=True)
    run = ds.ms_runs["run_0001"]
    run.encrypt_with_key(key, EncryptionLevel.DATASET)  # should be a no-op
    ds.close()

    # Decrypt via run.decrypt_with_key and verify plaintext matches
    ds = SpectralDataset.open(path)
    run = ds.ms_runs["run_0001"]
    plaintext = run.decrypt_with_key(key)
    ds.close()

    recovered = np.frombuffer(plaintext, dtype="<f8")
    np.testing.assert_array_equal(recovered, original_intensity)


def test_spectral_dataset_encrypt_all_runs(tmp_path):
    """SpectralDataset.encrypt_with_key encrypts every MS run at once."""
    from ttio import SpectralDataset
    from ttio.enums import EncryptionLevel

    path = str(tmp_path / "multi_run.tio")
    key = bytes(range(32))
    original = np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")

    _make_ttio_fixture(path, ["run_A", "run_B"])

    # Encrypt all runs at once via the dataset-level API (writable mode)
    ds = SpectralDataset.open(path, writable=True)
    ds.encrypt_with_key(key, EncryptionLevel.DATASET)
    ds.close()

    # Verify both runs encrypted on disk
    with h5py.File(path, "r") as f:
        for rname in ("run_A", "run_B"):
            sc = f[f"study/ms_runs/{rname}/signal_channels"]
            assert "intensity_values_encrypted" in sc, f"{rname}: encrypted missing"
            assert "intensity_values" not in sc, f"{rname}: plaintext not removed"

    # Decrypt both and verify
    ds = SpectralDataset.open(path)
    result = ds.decrypt_with_key(key)
    ds.close()

    assert set(result.keys()) == {"run_A", "run_B"}
    for rname, plaintext in result.items():
        recovered = np.frombuffer(plaintext, dtype="<f8")
        np.testing.assert_array_equal(recovered, original, err_msg=f"{rname} mismatch")
