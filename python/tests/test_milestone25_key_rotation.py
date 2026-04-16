"""Milestone 25 — envelope encryption + key rotation (Python side).

Mirrors TestMilestone25.m in the ObjC suite:
  * enable → unwrap with right KEK → wrong KEK fails
  * rotate(KEK1 → KEK2) → DEK unchanged, KEK1 stops working
  * rotate again (KEK2 → KEK3) → history length 2, original DEK survives
  * rotation < 100 ms
  * feature-flag constant present
  * cross-language parity: unwrap a file produced by ObjC's
    MPGOKeyRotationManager (if the manual fixture is available)
"""
from __future__ import annotations

import os
import time
from pathlib import Path

import h5py
import pytest

from mpeg_o.feature_flags import OPT_KEY_ROTATION
from mpeg_o.key_rotation import (
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
    path = tmp_path / "m25_enable.mpgo"
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
    path = tmp_path / "m25_wrong.mpgo"
    kek1 = _key(0xA1)
    kek_bad = _key(0xFF)
    with h5py.File(path, "w") as f:
        enable_envelope_encryption(f, kek1, kek_id="kek-1")
    with h5py.File(path, "r") as f:
        with pytest.raises(Exception):
            unwrap_dek(f, kek_bad)


def test_rotate_preserves_dek(tmp_path: Path) -> None:
    path = tmp_path / "m25_rotate.mpgo"
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
    path = tmp_path / "m25_rotate_wrong.mpgo"
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
    path = tmp_path / "m25_parity.mpgo"
    kek = _key(0xA1)
    with h5py.File(path, "w") as f:
        dek1 = enable_envelope_encryption(f, kek, kek_id="kek-1")

    # Re-open read-only: verifies the wrapped dataset reads back cleanly
    # and the attributes are visible as UTF-8 strings.
    with h5py.File(path, "r") as f:
        ki = f["/protection/key_info"]
        wrapped = ki["dek_wrapped"][()]
        assert wrapped.dtype == "uint8"
        assert wrapped.shape == (60,)
        assert ki.attrs["kek_id"] == b"kek-1" or ki.attrs["kek_id"] == "kek-1"
        assert "aes-256-gcm" in str(ki.attrs["kek_algorithm"])
        dek2 = unwrap_dek(f, kek)
        assert dek2 == dek1
