"""Tests for HMAC-SHA256 signatures (Python round-trip + ObjC parity)."""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np

from mpeg_o.encryption import AES_KEY_LEN
from mpeg_o.signatures import (
    SIGNATURE_ATTR,
    hmac_sha256_b64,
    sign_dataset,
    verify_dataset,
)

FIXTURE_KEY = bytes(0xA5 ^ (i * 3) & 0xFF for i in range(AES_KEY_LEN))


def test_sign_and_verify_round_trip(tmp_path: Path) -> None:
    p = tmp_path / "sig.h5"
    data = np.arange(100, dtype=np.float64)
    with h5py.File(p, "w") as f:
        f.create_dataset("x", data=data)
        mac = sign_dataset(f["x"], key=FIXTURE_KEY)
        assert isinstance(mac, str) and len(mac) > 0
    with h5py.File(p, "r") as f:
        assert verify_dataset(f["x"], key=FIXTURE_KEY) is True


def test_verify_rejects_wrong_key(tmp_path: Path) -> None:
    p = tmp_path / "sig.h5"
    data = np.arange(10, dtype=np.float64)
    with h5py.File(p, "w") as f:
        f.create_dataset("x", data=data)
        sign_dataset(f["x"], key=FIXTURE_KEY)
    with h5py.File(p, "r") as f:
        assert verify_dataset(f["x"], key=bytes(AES_KEY_LEN)) is False


def test_verify_missing_attribute(tmp_path: Path) -> None:
    p = tmp_path / "sig.h5"
    with h5py.File(p, "w") as f:
        f.create_dataset("x", data=np.zeros(3, dtype=np.float64))
    with h5py.File(p, "r") as f:
        assert verify_dataset(f["x"], key=FIXTURE_KEY) is False


def test_hmac_primitive_known_vector() -> None:
    """RFC 4231 test case 1 — sanity check the underlying primitive."""
    key = b"\x0b" * 20
    data = b"Hi There"
    import base64, hashlib, hmac as _hmac
    expected = base64.b64encode(_hmac.new(key, data, hashlib.sha256).digest()).decode()
    assert hmac_sha256_b64(data, key) == expected


def test_verify_objc_signed_fixture(signed_fixture: Path) -> None:
    """Cross-implementation parity: a Python verifier must accept
    signatures produced by the ObjC signer using the same key.

    v0.2 signatures are native-endian; this test runs on the host that
    produced the fixture (little-endian CI + developer workstations)."""
    with h5py.File(signed_fixture, "r") as f:
        run_sig = f["study/ms_runs/run_0001/signal_channels"]
        mz = run_sig["mz_values"]
        intensity = run_sig["intensity_values"]
        assert SIGNATURE_ATTR in mz.attrs
        assert SIGNATURE_ATTR in intensity.attrs
        assert verify_dataset(mz, key=FIXTURE_KEY) is True
        assert verify_dataset(intensity, key=FIXTURE_KEY) is True
