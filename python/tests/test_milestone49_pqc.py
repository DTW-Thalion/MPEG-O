"""Milestone 49 — Post-quantum crypto (Python side).

Covers:

* :mod:`ttio.pqc` thin-wrapper round-trips for ML-KEM-1024 and
  ML-DSA-87 (liboqs-python).
* :func:`ttio.signatures.sign_dataset` / ``verify_dataset`` with
  ``algorithm="ml-dsa-87"`` — v3: prefix emit, verify round trip,
  cross-algorithm rejection, backward compat with v2: HMAC.
* :mod:`ttio.key_rotation` ML-KEM-1024 envelope: enable → unwrap →
  rotate (including AES→PQC and PQC→AES migrations).
* ``opt_pqc_preview`` feature flag set exactly when a PQC primitive is
  activated on a file.

The whole module is skipped if ``liboqs-python`` / liboqs is not
importable — PQC is an optional extra.
"""
from __future__ import annotations

import json
from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio import cipher_suite, pqc
from ttio.cipher_suite import InvalidKeyError, UnsupportedAlgorithmError
from ttio.feature_flags import OPT_PQC_PREVIEW
from ttio.key_rotation import (
    KeyRotationError,
    enable_envelope_encryption,
    key_history,
    rotate_key,
    unwrap_dek,
    _MLKEM_CT_LEN,
    _pack_ml_kem_blob,
    _unpack_ml_kem_blob,
    _wrap_dek,
    _unwrap_dek,
)
from ttio.signatures import (
    SIGNATURE_ATTR,
    SIGNATURE_V2_PREFIX,
    SIGNATURE_V3_PREFIX,
    sign_dataset,
    verify_dataset,
)


pytestmark = pytest.mark.skipif(
    not pqc.is_available(),
    reason="liboqs-python / liboqs not installed — install with ttio[pqc]",
)


# --------------------------------------------- low-level PQC wrapper ---


def test_ml_kem_keygen_sizes() -> None:
    kp = pqc.kem_keygen()
    assert len(kp.public_key) == 1568
    assert len(kp.private_key) == 3168


def test_ml_kem_encap_decap_round_trip() -> None:
    kp = pqc.kem_keygen()
    ct, ss_a = pqc.kem_encapsulate(kp.public_key)
    assert len(ct) == 1568
    assert len(ss_a) == 32
    ss_b = pqc.kem_decapsulate(kp.private_key, ct)
    assert ss_a == ss_b


def test_ml_dsa_keygen_sizes() -> None:
    kp = pqc.sig_keygen()
    assert len(kp.public_key) == 2592
    assert len(kp.private_key) == 4896


def test_ml_dsa_sign_verify() -> None:
    kp = pqc.sig_keygen()
    msg = b"the quick brown fox jumps over the lazy dog"
    sig = pqc.sig_sign(kp.private_key, msg)
    assert len(sig) == 4627
    assert pqc.sig_verify(kp.public_key, msg, sig) is True
    # Tamper with the message — verify must fail.
    assert pqc.sig_verify(kp.public_key, msg + b"!", sig) is False
    # Tamper with the signature.
    bad = bytearray(sig)
    bad[0] ^= 0xFF
    assert pqc.sig_verify(kp.public_key, msg, bytes(bad)) is False


# ------------------------------------------------- catalog integration ---


def test_catalog_pqc_active() -> None:
    assert cipher_suite.is_supported("ml-kem-1024")
    assert cipher_suite.is_supported("ml-dsa-87")
    assert cipher_suite.public_key_size("ml-kem-1024") == 1568
    assert cipher_suite.private_key_size("ml-kem-1024") == 3168
    assert cipher_suite.public_key_size("ml-dsa-87") == 2592
    assert cipher_suite.private_key_size("ml-dsa-87") == 4896


def test_validate_key_rejects_asymmetric() -> None:
    with pytest.raises(InvalidKeyError, match="asymmetric"):
        cipher_suite.validate_key("ml-kem-1024", b"\x00" * 1568)
    with pytest.raises(InvalidKeyError, match="asymmetric"):
        cipher_suite.validate_key("ml-dsa-87", b"\x00" * 4896)


def test_validate_public_private_key_roles() -> None:
    # Right lengths: no-ops.
    cipher_suite.validate_public_key("ml-kem-1024", b"\x00" * 1568)
    cipher_suite.validate_private_key("ml-kem-1024", b"\x00" * 3168)
    # Swapped pk/sk must fail.
    with pytest.raises(InvalidKeyError, match="public key must be"):
        cipher_suite.validate_public_key("ml-kem-1024", b"\x00" * 3168)
    with pytest.raises(InvalidKeyError, match="private key must be"):
        cipher_suite.validate_private_key("ml-kem-1024", b"\x00" * 1568)


# -------------------------------------------------- v3: signatures ---


def _signable_dataset(f: h5py.File) -> h5py.Dataset:
    """Create a stable canonical-byte dataset for signature tests."""
    arr = np.arange(64, dtype="<f8")
    return f.create_dataset("payload", data=arr)


def test_ml_dsa_sign_verify_roundtrip(tmp_path: Path) -> None:
    path = tmp_path / "sig_v3.tio"
    kp = pqc.sig_keygen()
    with h5py.File(path, "w") as f:
        ds = _signable_dataset(f)
        prefixed = sign_dataset(ds, kp.private_key, algorithm="ml-dsa-87")
        assert prefixed.startswith(SIGNATURE_V3_PREFIX)

    with h5py.File(path, "r") as f:
        ds = f["payload"]
        assert verify_dataset(ds, kp.public_key, algorithm="ml-dsa-87")


def test_v3_verify_rejects_tampered_payload(tmp_path: Path) -> None:
    path = tmp_path / "sig_v3_tamper.tio"
    kp = pqc.sig_keygen()
    with h5py.File(path, "w") as f:
        ds = _signable_dataset(f)
        sign_dataset(ds, kp.private_key, algorithm="ml-dsa-87")

    with h5py.File(path, "r+") as f:
        ds = f["payload"]
        ds[0] = 999.0
    with h5py.File(path, "r") as f:
        ds = f["payload"]
        assert verify_dataset(ds, kp.public_key, algorithm="ml-dsa-87") is False


def test_v3_verify_wrong_algorithm_mix(tmp_path: Path) -> None:
    """Verifier refuses to check a v3 blob with algorithm='hmac-sha256'
    (and vice-versa), preventing silent drift."""
    path = tmp_path / "sig_mix.tio"
    hmac_key = b"\xA1" * 32
    kp = pqc.sig_keygen()
    with h5py.File(path, "w") as f:
        ds = _signable_dataset(f)
        sign_dataset(ds, kp.private_key, algorithm="ml-dsa-87")

    with h5py.File(path, "r") as f:
        ds = f["payload"]
        with pytest.raises(UnsupportedAlgorithmError, match="v3"):
            verify_dataset(ds, hmac_key, algorithm="hmac-sha256")

    # And the reverse: v2-stored, verifier asks for v3.
    path2 = tmp_path / "sig_mix_v2.tio"
    with h5py.File(path2, "w") as f:
        ds = _signable_dataset(f)
        sign_dataset(ds, hmac_key, algorithm="hmac-sha256")
    with h5py.File(path2, "r") as f:
        ds = f["payload"]
        with pytest.raises(UnsupportedAlgorithmError, match="not v3"):
            verify_dataset(ds, kp.public_key, algorithm="ml-dsa-87")


def test_v2_backward_compat_with_pqc_build(tmp_path: Path) -> None:
    """A file signed with v2 HMAC still verifies under the same build
    that ships PQC. Legacy guarantee (HANDOFF binding #44)."""
    path = tmp_path / "sig_v2_compat.tio"
    hmac_key = b"\xC3" * 32
    with h5py.File(path, "w") as f:
        ds = _signable_dataset(f)
        sign_dataset(ds, hmac_key, algorithm="hmac-sha256")
    with h5py.File(path, "r") as f:
        ds = f["payload"]
        assert verify_dataset(ds, hmac_key, algorithm="hmac-sha256")


# -------------------------------------------------- ML-KEM envelope ---


def test_ml_kem_enable_unwrap_roundtrip(tmp_path: Path) -> None:
    path = tmp_path / "env_kem.tio"
    kp = pqc.kem_keygen()
    with h5py.File(path, "w") as f:
        dek_a = enable_envelope_encryption(
            f, kp.public_key, kek_id="kem-1", algorithm="ml-kem-1024"
        )
        assert len(dek_a) == 32

    with h5py.File(path, "r") as f:
        dek_b = unwrap_dek(f, kp.private_key, algorithm="ml-kem-1024")
    assert dek_a == dek_b


def test_ml_kem_wrong_private_key_fails(tmp_path: Path) -> None:
    path = tmp_path / "env_kem_bad.tio"
    kp_good = pqc.kem_keygen()
    kp_bad = pqc.kem_keygen()
    with h5py.File(path, "w") as f:
        enable_envelope_encryption(
            f, kp_good.public_key, kek_id="kem-1", algorithm="ml-kem-1024"
        )
    with h5py.File(path, "r") as f:
        with pytest.raises(Exception):
            # ML-KEM decapsulation with wrong sk yields garbage shared
            # secret → AES-GCM auth-tag fails.
            unwrap_dek(f, kp_bad.private_key, algorithm="ml-kem-1024")


def test_ml_kem_blob_length_matches_spec(tmp_path: Path) -> None:
    """On-disk v1.2 ML-KEM blob = 11 header + 1596 metadata + 32
    ciphertext = 1639 bytes. Regression check for format stability."""
    path = tmp_path / "env_kem_len.tio"
    kp = pqc.kem_keygen()
    with h5py.File(path, "w") as f:
        enable_envelope_encryption(
            f, kp.public_key, kek_id="kem-1", algorithm="ml-kem-1024"
        )
    with h5py.File(path, "r") as f:
        wrapped = f["/protection/key_info/dek_wrapped"][()]
        assert wrapped.shape == (1639,)
        assert bytes(wrapped[:3]) == b"MW\x02"
        assert bytes(wrapped[3:5]) == b"\x00\x01"  # ML-KEM-1024 algorithm_id


def test_ml_kem_enable_wrong_key_shape(tmp_path: Path) -> None:
    """Passing an ML-KEM *private* key to a writer must fail the
    validate_public_key guard."""
    path = tmp_path / "env_kem_wrong_shape.tio"
    kp = pqc.kem_keygen()
    with h5py.File(path, "w") as f:
        with pytest.raises(InvalidKeyError, match="public key"):
            enable_envelope_encryption(
                f, kp.private_key, kek_id="kem-1", algorithm="ml-kem-1024"
            )


def test_ml_kem_pqc_preview_flag_set(tmp_path: Path) -> None:
    path = tmp_path / "env_kem_flag.tio"
    kp = pqc.kem_keygen()
    with h5py.File(path, "w") as f:
        # Seed @ttio_features so _mark_pqc_preview has something to append to.
        f.attrs["ttio_features"] = json.dumps(["base_v1"])
        enable_envelope_encryption(
            f, kp.public_key, kek_id="kem-1", algorithm="ml-kem-1024"
        )
    with h5py.File(path, "r") as f:
        features = json.loads(f.attrs["ttio_features"])
        assert OPT_PQC_PREVIEW in features


def test_aes_envelope_does_not_mark_pqc_preview(tmp_path: Path) -> None:
    path = tmp_path / "env_aes_noflag.tio"
    kek = b"\xA1" * 32
    with h5py.File(path, "w") as f:
        f.attrs["ttio_features"] = json.dumps(["base_v1"])
        enable_envelope_encryption(f, kek, kek_id="aes-1")
    with h5py.File(path, "r") as f:
        features = json.loads(f.attrs["ttio_features"])
        assert OPT_PQC_PREVIEW not in features


# -------------------------------------------------- rotation across algos ---


def test_rotate_aes_to_ml_kem(tmp_path: Path) -> None:
    path = tmp_path / "rot_aes_to_kem.tio"
    aes_kek = b"\xA1" * 32
    kem_kp = pqc.kem_keygen()

    with h5py.File(path, "w") as f:
        f.attrs["ttio_features"] = json.dumps(["base_v1"])
        dek_original = enable_envelope_encryption(f, aes_kek, kek_id="aes-1")

    with h5py.File(path, "r+") as f:
        rotate_key(
            f,
            old_kek=aes_kek,
            new_kek=kem_kp.public_key,
            new_kek_id="kem-1",
            algorithm="aes-256-gcm",
            new_algorithm="ml-kem-1024",
        )
        # Old AES KEK must no longer work.
        with pytest.raises(Exception):
            unwrap_dek(f, aes_kek, algorithm="aes-256-gcm")
        # New PQC sk unwraps to the same DEK.
        dek_after = unwrap_dek(
            f, kem_kp.private_key, algorithm="ml-kem-1024"
        )
        assert dek_after == dek_original
        # History carries the AES entry.
        hist = key_history(f)
        assert len(hist) == 1
        assert hist[0]["kek_algorithm"] == "aes-256-gcm"
    with h5py.File(path, "r") as f:
        features = json.loads(f.attrs["ttio_features"])
        assert OPT_PQC_PREVIEW in features


def test_rotate_ml_kem_to_aes(tmp_path: Path) -> None:
    path = tmp_path / "rot_kem_to_aes.tio"
    kem_kp = pqc.kem_keygen()
    aes_kek = b"\xB2" * 32

    with h5py.File(path, "w") as f:
        f.attrs["ttio_features"] = json.dumps(["base_v1"])
        dek_original = enable_envelope_encryption(
            f, kem_kp.public_key, kek_id="kem-1", algorithm="ml-kem-1024"
        )

    with h5py.File(path, "r+") as f:
        rotate_key(
            f,
            old_kek=kem_kp.private_key,
            new_kek=aes_kek,
            new_kek_id="aes-1",
            algorithm="ml-kem-1024",
            new_algorithm="aes-256-gcm",
        )
        dek_after = unwrap_dek(f, aes_kek, algorithm="aes-256-gcm")
        assert dek_after == dek_original


# -------------------------------------------------- blob pack/unpack ---


def test_ml_kem_blob_pack_unpack_symmetry() -> None:
    kem_ct = bytes(range(256)) * 7
    kem_ct = kem_ct[:_MLKEM_CT_LEN]
    iv = b"\x01" * 12
    tag = b"\x02" * 16
    wrapped = b"\x03" * 32
    blob = _pack_ml_kem_blob(kem_ct, iv, tag, wrapped)
    assert len(blob) == 11 + 1596 + 32
    r_ct, r_iv, r_tag, r_wr = _unpack_ml_kem_blob(blob)
    assert (r_ct, r_iv, r_tag, r_wr) == (kem_ct, iv, tag, wrapped)


def test_wrap_unwrap_via_underscore_helpers() -> None:
    """Exercise _wrap_dek / _unwrap_dek directly for the ML-KEM path —
    the public API wraps these, but the helpers are imported by other
    tests in the repo."""
    kp = pqc.kem_keygen()
    dek = b"\xAB" * 32
    wrapped = _wrap_dek(dek, kp.public_key, algorithm="ml-kem-1024")
    recovered = _unwrap_dek(wrapped, kp.private_key, algorithm="ml-kem-1024")
    assert recovered == dek
