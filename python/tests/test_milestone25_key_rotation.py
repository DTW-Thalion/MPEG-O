"""Milestone 25 — envelope encryption + key rotation (Python side).

Mirrors TestMilestone25.m in the ObjC suite:
  * enable → unwrap with right KEK → wrong KEK fails
  * rotate(KEK1 → KEK2) → DEK unchanged, KEK1 stops working
  * rotate again (KEK2 → KEK3) → history length 2, original DEK survives
  * rotation < 100 ms
  * feature-flag constant present
  * cross-language parity: unwrap a file produced by ObjC's
    TTIOKeyRotationManager (if the manual fixture is available)
"""
from __future__ import annotations

import os
import time
from pathlib import Path

import h5py
import pytest

from ttio.feature_flags import OPT_KEY_ROTATION
from ttio.key_rotation import (
    KeyRotationError,
    enable_envelope_encryption,
    has_envelope_encryption,
    key_history,
    rotate_key,
    unwrap_dek,
)


def _key(seed: int) -> bytes:
    return bytes([(seed ^ (i * 7 + 13)) & 0xFF for i in range(32)])


def test_feature_flag_constant() -> None:
    assert OPT_KEY_ROTATION == "opt_key_rotation"


def test_enable_and_unwrap(tmp_path: Path) -> None:
    path = tmp_path / "m25_enable.tio"
    kek1 = _key(0xA1)
    with h5py.File(path, "w") as f:
        assert not has_envelope_encryption(f)
        dek = enable_envelope_encryption(f, kek1, kek_id="kek-1")
        assert len(dek) == 32
        assert has_envelope_encryption(f)
        # Round-trip with the same KEK.
        recovered = unwrap_dek(f, kek1)
        assert recovered == dek


def test_wrong_kek_fails(tmp_path: Path) -> None:
    path = tmp_path / "m25_wrong.tio"
    kek1 = _key(0xA1)
    kek_bad = _key(0xFF)
    with h5py.File(path, "w") as f:
        enable_envelope_encryption(f, kek1, kek_id="kek-1")
    with h5py.File(path, "r") as f:
        with pytest.raises(Exception):
            unwrap_dek(f, kek_bad)


def test_rotate_preserves_dek(tmp_path: Path) -> None:
    path = tmp_path / "m25_rotate.tio"
    kek1 = _key(0xA1)
    kek2 = _key(0xB2)
    kek3 = _key(0xC3)

    with h5py.File(path, "w") as f:
        dek_original = enable_envelope_encryption(f, kek1, kek_id="kek-1")

    with h5py.File(path, "r+") as f:
        t0 = time.perf_counter()
        rotate_key(f, old_kek=kek1, new_kek=kek2, new_kek_id="kek-2")
        elapsed = time.perf_counter() - t0
        assert elapsed < 0.100, f"rotation took {elapsed*1000:.1f} ms"
        dek_after = unwrap_dek(f, kek2)
        assert dek_after == dek_original

        # KEK-1 must no longer work.
        with pytest.raises(Exception):
            unwrap_dek(f, kek1)

        hist = key_history(f)
        assert len(hist) == 1
        assert hist[0]["kek_id"] == "kek-1"
        assert hist[0]["kek_algorithm"] == "aes-256-gcm"

        # Second rotation.
        rotate_key(f, old_kek=kek2, new_kek=kek3, new_kek_id="kek-3")
        hist = key_history(f)
        assert len(hist) == 2
        assert hist[1]["kek_id"] == "kek-2"

        dek_final = unwrap_dek(f, kek3)
        assert dek_final == dek_original


def test_rotate_with_wrong_old_kek_fails(tmp_path: Path) -> None:
    path = tmp_path / "m25_rotate_wrong.tio"
    kek1 = _key(0xA1)
    kek_bad = _key(0xFF)
    kek2 = _key(0xB2)

    with h5py.File(path, "w") as f:
        enable_envelope_encryption(f, kek1, kek_id="kek-1")

    with h5py.File(path, "r+") as f:
        with pytest.raises(Exception):
            rotate_key(f, old_kek=kek_bad, new_kek=kek2, new_kek_id="kek-2")
        # State must be unchanged — KEK-1 still works, no history grown.
        assert unwrap_dek(f, kek1) is not None
        assert key_history(f) == []


def test_cross_language_parity(tmp_path: Path) -> None:
    """Python enables envelope, ObjC reads it (via fixture); and vice-versa.

    This test is intentionally structural: it verifies the wire layout
    is stable by producing the file and re-reading it within the same
    process, which exercises the exact byte-level packing used by the
    cross-language comparison. A real end-to-end ObjC<->Python test
    requires the ObjC test binary to generate a fixture; that path is
    covered in the ObjC suite (TestMilestone25.m).
    """
    path = tmp_path / "m25_parity.tio"
    kek = _key(0xA1)
    with h5py.File(path, "w") as f:
        dek1 = enable_envelope_encryption(f, kek, kek_id="kek-1")

    # Re-open read-only: verifies the wrapped dataset reads back cleanly
    # and the attributes are visible as UTF-8 strings.
    with h5py.File(path, "r") as f:
        ki = f["/protection/key_info"]
        wrapped = ki["dek_wrapped"][()]
        assert wrapped.dtype == "uint8"
        # v0.7 M47: default output is the v1.2 wrapped-key blob (71 bytes
        # for AES-256-GCM: 11-byte header + 28-byte metadata + 32-byte
        # ciphertext). v1.1 legacy (60 bytes) remains readable — see
        # test_v11_backward_compat_unwrap below.
        assert wrapped.shape == (71,)
        # Magic bytes "MW" + version 0x02 + algorithm_id 0x0000 (AES-256-GCM)
        assert bytes(wrapped[:3]) == b"MW\x02"
        assert bytes(wrapped[3:5]) == b"\x00\x00"
        assert ki.attrs["kek_id"] == b"kek-1" or ki.attrs["kek_id"] == "kek-1"
        assert "aes-256-gcm" in str(ki.attrs["kek_algorithm"])
        dek2 = unwrap_dek(f, kek)
        assert dek2 == dek1


def test_v11_backward_compat_unwrap(tmp_path: Path) -> None:
    """M47 Binding Decision 38: the v1.1 60-byte AES-256-GCM wrapped
    blob remains readable forever. Hand-craft a v1.1 file and verify
    v0.7+ code unwraps it correctly."""
    from ttio.key_rotation import _wrap_dek, _write_wrapped_dataset
    import numpy as np

    path = tmp_path / "m47_legacy_v11.tio"
    kek = _key(0xB2)
    dek = _key(0xC3)
    # Produce the v1.1 layout explicitly via the legacy path.
    legacy_blob = _wrap_dek(dek, kek, legacy_v1=True)
    assert len(legacy_blob) == 60

    with h5py.File(path, "w") as f:
        prot = f.create_group("protection")
        ki = prot.create_group("key_info")
        _write_wrapped_dataset(ki, legacy_blob)
        ki.attrs["kek_id"] = np.bytes_(b"legacy-kek")
        ki.attrs["kek_algorithm"] = np.bytes_(b"aes-256-gcm")

    with h5py.File(path, "r") as f:
        assert unwrap_dek(f, kek) == dek


def test_v12_reject_unknown_algorithm(tmp_path: Path) -> None:
    """A v1.2 blob carrying a reserved algorithm id (e.g. ML-KEM-1024,
    M49) must raise UnsupportedWrappedBlobError — not a garbled
    decrypt error."""
    from ttio.key_rotation import (
        UnsupportedWrappedBlobError,
        _WK_ALG_ML_KEM_1024,
        _pack_blob_v2,
        _unwrap_dek,
    )

    # Hand-craft a dummy ML-KEM blob (1568-byte ciphertext, 0-byte metadata).
    pqc_ciphertext = bytes(range(256)) * 7  # 1792 bytes — any non-60
    pqc_ciphertext = pqc_ciphertext[:1568]
    dummy = _pack_blob_v2(
        _WK_ALG_ML_KEM_1024,
        ciphertext=pqc_ciphertext,
        metadata=b"",
    )
    try:
        _unwrap_dek(dummy, _key(0xD4))
    except UnsupportedWrappedBlobError as e:
        assert "0x0001" in str(e)
    else:
        raise AssertionError("expected UnsupportedWrappedBlobError")
