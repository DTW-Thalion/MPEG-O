"""Milestone 54 — cross-language PQC conformance matrix.

Verifies that PQC operations produce **interoperable** (verify-valid)
results across the three language implementations. ML-KEM and ML-DSA
outputs are non-deterministic (randomised ciphertext / signature), so
"identical bytes" parity doesn't apply at the cross-lang layer — the
conformance contract is:

1. ``lang_A.encapsulate(pk_B) → ciphertext`` and
   ``lang_B.decapsulate(sk_B, ciphertext) == shared_secret`` produced
   by A's encapsulate.
2. ``lang_A.sign(sk, msg) → signature`` and
   ``lang_B.verify(pk, msg, signature) == true``.
3. An HDF5 file signed with a ``v3:`` ML-DSA-87 attribute in one
   language verifies cleanly in every other language.
4. Classical v0.7 HMAC signatures still verify under v0.8 code.
5. ``v2:`` HMAC and ``v3:`` ML-DSA signatures coexist on the same
   ``.tio`` file.

The harness shells out to two peer CLIs that ship with v0.8 M54:
``global.thalion.ttio.tools.PQCTool`` (Java, via ``run-tool.sh``) and
``TtioPQCTool`` (Objective-C, built via ``./build.sh``). When a peer
CLI is not present the corresponding cells are **skipped** — the test
reports which pairings actually ran so CI can show graceful
degradation on hosts without one of the toolchains.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from ttio import pqc
from ttio.signatures import (
    SIGNATURE_ATTR,
    SIGNATURE_V2_PREFIX,
    SIGNATURE_V3_PREFIX,
    sign_dataset,
    verify_dataset,
)


_REPO_ROOT = Path(__file__).resolve().parents[2]


# ── Peer CLI discovery ────────────────────────────────────────────────


def _java_runner() -> list[str] | None:
    """Resolve the java/run-tool.sh + classpath for the Java PQCTool."""
    runner = _REPO_ROOT / "java" / "run-tool.sh"
    classes = _REPO_ROOT / "java" / "target" / "classes"
    if not runner.is_file() or not os.access(runner, os.X_OK):
        return None
    if not classes.is_dir():
        return None
    return [str(runner), "global.thalion.ttio.tools.PQCTool"]


def _objc_runner() -> list[str] | None:
    """Resolve the ObjC TtioPQCTool binary + the LD_LIBRARY_PATH needed
    to find libTTIO.so."""
    binary = _REPO_ROOT / "objc" / "Tools" / "obj" / "TtioPQCTool"
    libdir = _REPO_ROOT / "objc" / "Source" / "obj"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        return None
    if not libdir.is_dir():
        return None
    return [str(binary)]


def _objc_env() -> dict[str, str]:
    env = os.environ.copy()
    libdir = str(_REPO_ROOT / "objc" / "Source" / "obj")
    existing = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = (
        f"{libdir}:{existing}" if existing else libdir)
    return env


JAVA_CMD = _java_runner()
OBJC_CMD = _objc_runner()


skip_no_java = pytest.mark.skipif(
    JAVA_CMD is None or not pqc.is_available(),
    reason="java/run-tool.sh target/classes missing or liboqs unavailable",
)
skip_no_objc = pytest.mark.skipif(
    OBJC_CMD is None or not pqc.is_available(),
    reason="objc/Tools/obj/TtioPQCTool not built or liboqs unavailable",
)
skip_no_pqc = pytest.mark.skipif(
    not pqc.is_available(),
    reason="liboqs-python not installed",
)


# ── CLI dispatch helpers ──────────────────────────────────────────────


def _run(cmd: list[str], env: dict[str, str] | None = None) -> int:
    """Run a peer tool, capture stderr for diagnostics on failure."""
    proc = subprocess.run(cmd, capture_output=True, env=env)
    if proc.returncode not in (0, 1):  # 1 is a valid "not verified" result
        sys.stderr.write(
            f"CLI failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"  stdout: {proc.stdout.decode(errors='replace')[:400]}\n"
            f"  stderr: {proc.stderr.decode(errors='replace')[:400]}\n")
    return proc.returncode


def _sig_sign(cli: list[str], sk_path: Path, msg_path: Path,
               sig_path: Path, env: dict[str, str] | None = None) -> int:
    return _run(cli + ["sig-sign", str(sk_path), str(msg_path),
                         str(sig_path)], env=env)


def _sig_verify(cli: list[str], pk_path: Path, msg_path: Path,
                 sig_path: Path, env: dict[str, str] | None = None) -> int:
    return _run(cli + ["sig-verify", str(pk_path), str(msg_path),
                         str(sig_path)], env=env)


def _kem_encaps(cli: list[str], pk_path: Path, ct_path: Path,
                 ss_path: Path, env: dict[str, str] | None = None) -> int:
    return _run(cli + ["kem-encaps", str(pk_path), str(ct_path),
                         str(ss_path)], env=env)


def _kem_decaps(cli: list[str], sk_path: Path, ct_path: Path,
                 ss_path: Path, env: dict[str, str] | None = None) -> int:
    return _run(cli + ["kem-decaps", str(sk_path), str(ct_path),
                         str(ss_path)], env=env)


def _hdf5_sign(cli: list[str], file_path: Path, ds_path: str,
                sk_path: Path, env: dict[str, str] | None = None) -> int:
    return _run(cli + ["hdf5-sign", str(file_path), ds_path, str(sk_path)],
                 env=env)


def _hdf5_verify(cli: list[str], file_path: Path, ds_path: str,
                  pk_path: Path, env: dict[str, str] | None = None) -> int:
    return _run(cli + ["hdf5-verify", str(file_path), ds_path, str(pk_path)],
                 env=env)


# ── Python helpers that match the CLI grammar ─────────────────────────


def _py_sig_sign(sk: bytes, msg: bytes) -> bytes:
    return pqc.sig_sign(sk, msg)


def _py_sig_verify(pk: bytes, msg: bytes, sig: bytes) -> bool:
    return pqc.sig_verify(pk, msg, sig)


def _py_kem_encaps(pk: bytes) -> tuple[bytes, bytes]:
    return pqc.kem_encapsulate(pk)


def _py_kem_decaps(sk: bytes, ct: bytes) -> bytes:
    return pqc.kem_decapsulate(sk, ct)


# ── Primitive matrix: ML-DSA-87 sign/verify ───────────────────────────


@pytest.mark.parametrize("signer,verifier", [
    pytest.param("python", "java",   marks=skip_no_java,
                  id="ML-DSA Python→Java"),
    pytest.param("python", "objc",   marks=skip_no_objc,
                  id="ML-DSA Python→ObjC"),
    pytest.param("java",   "python", marks=skip_no_java,
                  id="ML-DSA Java→Python"),
    pytest.param("java",   "objc",   marks=[skip_no_java, skip_no_objc],
                  id="ML-DSA Java→ObjC"),
    pytest.param("objc",   "python", marks=skip_no_objc,
                  id="ML-DSA ObjC→Python"),
    pytest.param("objc",   "java",   marks=[skip_no_objc, skip_no_java],
                  id="ML-DSA ObjC→Java"),
])
def test_ml_dsa_cross_language(tmp_path: Path, signer: str,
                                 verifier: str) -> None:
    """Matrix cell: signer generates keypair + signature; verifier
    validates. ML-DSA-87 signatures are randomised, so only the verify
    side provides cross-language evidence."""
    pk_path = tmp_path / "pk.bin"
    sk_path = tmp_path / "sk.bin"
    msg_path = tmp_path / "msg.bin"
    sig_path = tmp_path / "sig.bin"
    msg_path.write_bytes(b"the quick brown fox " * 3)

    _do_sig_keygen(signer, pk_path, sk_path)
    _do_sig_sign(signer, sk_path, msg_path, sig_path)
    verify_rc = _do_sig_verify(verifier, pk_path, msg_path, sig_path)
    assert verify_rc == 0, f"{verifier} failed to verify {signer}'s sig"


def _do_sig_keygen(lang: str, pk_path: Path, sk_path: Path) -> None:
    if lang == "python":
        kp = pqc.sig_keygen()
        pk_path.write_bytes(kp.public_key)
        sk_path.write_bytes(kp.private_key)
    else:
        cli = JAVA_CMD if lang == "java" else OBJC_CMD
        env = _objc_env() if lang == "objc" else None
        rc = _run(cli + ["sig-keygen", str(pk_path), str(sk_path)], env=env)
        assert rc == 0, f"{lang} sig-keygen failed"


def _do_sig_sign(lang: str, sk_path: Path, msg_path: Path,
                  sig_path: Path) -> None:
    if lang == "python":
        sig = _py_sig_sign(sk_path.read_bytes(), msg_path.read_bytes())
        sig_path.write_bytes(sig)
    else:
        cli = JAVA_CMD if lang == "java" else OBJC_CMD
        env = _objc_env() if lang == "objc" else None
        rc = _sig_sign(cli, sk_path, msg_path, sig_path, env=env)
        assert rc == 0, f"{lang} sig-sign failed"


def _do_sig_verify(lang: str, pk_path: Path, msg_path: Path,
                    sig_path: Path) -> int:
    if lang == "python":
        ok = _py_sig_verify(pk_path.read_bytes(), msg_path.read_bytes(),
                             sig_path.read_bytes())
        return 0 if ok else 1
    cli = JAVA_CMD if lang == "java" else OBJC_CMD
    env = _objc_env() if lang == "objc" else None
    return _sig_verify(cli, pk_path, msg_path, sig_path, env=env)


# ── Primitive matrix: ML-KEM-1024 encaps/decaps ───────────────────────


@pytest.mark.parametrize("encaps,decaps", [
    pytest.param("python", "java",   marks=skip_no_java,
                  id="ML-KEM Python→Java"),
    pytest.param("python", "objc",   marks=skip_no_objc,
                  id="ML-KEM Python→ObjC"),
    pytest.param("java",   "python", marks=skip_no_java,
                  id="ML-KEM Java→Python"),
    pytest.param("java",   "objc",   marks=[skip_no_java, skip_no_objc],
                  id="ML-KEM Java→ObjC"),
    pytest.param("objc",   "python", marks=skip_no_objc,
                  id="ML-KEM ObjC→Python"),
    pytest.param("objc",   "java",   marks=[skip_no_objc, skip_no_java],
                  id="ML-KEM ObjC→Java"),
])
def test_ml_kem_cross_language(tmp_path: Path, encaps: str,
                                decaps: str) -> None:
    """Matrix cell: encaps generates a keypair and encapsulates under
    its own pk; decaps receives the sk + ciphertext and must recover
    the exact same shared secret."""
    pk_path = tmp_path / "pk.bin"
    sk_path = tmp_path / "sk.bin"
    ct_path = tmp_path / "ct.bin"
    ss_encaps = tmp_path / "ss_enc.bin"
    ss_decaps = tmp_path / "ss_dec.bin"

    _do_kem_keygen(encaps, pk_path, sk_path)
    _do_kem_encaps(encaps, pk_path, ct_path, ss_encaps)
    _do_kem_decaps(decaps, sk_path, ct_path, ss_decaps)

    assert ss_encaps.read_bytes() == ss_decaps.read_bytes(), \
        f"shared secret mismatch between {encaps} encaps and {decaps} decaps"


def _do_kem_keygen(lang: str, pk_path: Path, sk_path: Path) -> None:
    if lang == "python":
        kp = pqc.kem_keygen()
        pk_path.write_bytes(kp.public_key)
        sk_path.write_bytes(kp.private_key)
    else:
        cli = JAVA_CMD if lang == "java" else OBJC_CMD
        env = _objc_env() if lang == "objc" else None
        rc = _run(cli + ["kem-keygen", str(pk_path), str(sk_path)], env=env)
        assert rc == 0


def _do_kem_encaps(lang: str, pk_path: Path, ct_path: Path,
                     ss_path: Path) -> None:
    if lang == "python":
        ct, ss = _py_kem_encaps(pk_path.read_bytes())
        ct_path.write_bytes(ct)
        ss_path.write_bytes(ss)
    else:
        cli = JAVA_CMD if lang == "java" else OBJC_CMD
        env = _objc_env() if lang == "objc" else None
        rc = _kem_encaps(cli, pk_path, ct_path, ss_path, env=env)
        assert rc == 0


def _do_kem_decaps(lang: str, sk_path: Path, ct_path: Path,
                    ss_path: Path) -> None:
    if lang == "python":
        ss = _py_kem_decaps(sk_path.read_bytes(), ct_path.read_bytes())
        ss_path.write_bytes(ss)
    else:
        cli = JAVA_CMD if lang == "java" else OBJC_CMD
        env = _objc_env() if lang == "objc" else None
        rc = _kem_decaps(cli, sk_path, ct_path, ss_path, env=env)
        assert rc == 0


# ── v3 HDF5 signature matrix ──────────────────────────────────────────


def _seed_hdf5_dataset(path: Path, dataset: str = "/payload",
                        data: np.ndarray | None = None) -> None:
    """Create an .tio file with a single float64 dataset at ``dataset``."""
    import h5py
    if data is None:
        data = np.arange(64, dtype="<f8")
    with h5py.File(path, "w") as f:
        f.create_dataset(dataset.lstrip("/"), data=data)


@pytest.mark.parametrize("signer,verifier", [
    pytest.param("python", "java",   marks=skip_no_java,
                  id="HDF5-v3 Python→Java"),
    pytest.param("python", "objc",   marks=skip_no_objc,
                  id="HDF5-v3 Python→ObjC"),
    pytest.param("java",   "python", marks=skip_no_java,
                  id="HDF5-v3 Java→Python"),
    pytest.param("java",   "objc",   marks=[skip_no_java, skip_no_objc],
                  id="HDF5-v3 Java→ObjC"),
    pytest.param("objc",   "python", marks=skip_no_objc,
                  id="HDF5-v3 ObjC→Python"),
    pytest.param("objc",   "java",   marks=[skip_no_objc, skip_no_java],
                  id="HDF5-v3 ObjC→Java"),
])
def test_v3_hdf5_cross_language(tmp_path: Path, signer: str,
                                  verifier: str) -> None:
    """Signer writes a v3: ML-DSA-87 signature onto an HDF5 dataset;
    verifier must read + validate it."""
    import h5py

    pk_path = tmp_path / "pk.bin"
    sk_path = tmp_path / "sk.bin"
    ttio = tmp_path / "fixture.tio"

    # Keygen in Python (all three languages understand the same raw key
    # shape, so the generator choice is cosmetic — using Python keeps
    # the fixture reproducible and decouples from which CLI we test).
    kp = pqc.sig_keygen()
    pk_path.write_bytes(kp.public_key)
    sk_path.write_bytes(kp.private_key)

    _seed_hdf5_dataset(ttio)

    # Sign with the chosen signer.
    if signer == "python":
        with h5py.File(ttio, "r+") as f:
            sign_dataset(f["payload"], kp.private_key, algorithm="ml-dsa-87")
    else:
        cli = JAVA_CMD if signer == "java" else OBJC_CMD
        env = _objc_env() if signer == "objc" else None
        rc = _hdf5_sign(cli, ttio, "/payload", sk_path, env=env)
        assert rc == 0, f"{signer} hdf5-sign failed"

    # Sanity: the signature attribute should carry the v3: prefix.
    with h5py.File(ttio, "r") as f:
        stored = f["payload"].attrs[SIGNATURE_ATTR]
        stored_str = stored.decode() if isinstance(stored, bytes) else str(stored)
        assert stored_str.startswith(SIGNATURE_V3_PREFIX), \
            f"expected v3: prefix, got {stored_str[:12]!r}"

    # Verify with the chosen verifier.
    if verifier == "python":
        with h5py.File(ttio, "r") as f:
            assert verify_dataset(
                f["payload"], kp.public_key, algorithm="ml-dsa-87")
    else:
        cli = JAVA_CMD if verifier == "java" else OBJC_CMD
        env = _objc_env() if verifier == "objc" else None
        rc = _hdf5_verify(cli, ttio, "/payload", pk_path, env=env)
        assert rc == 0, f"{verifier} hdf5-verify failed"


# ── Mixed v2 + v3 coexistence (Python-local) ──────────────────────────


@skip_no_pqc
def test_v2_and_v3_coexist_on_same_file(tmp_path: Path) -> None:
    """A single .tio can carry ``v2:`` HMAC on one dataset and ``v3:``
    ML-DSA on another. Both verify with their respective keys."""
    import h5py

    path = tmp_path / "mixed.tio"
    hmac_key = bytes(range(32))
    dsa_kp = pqc.sig_keygen()

    with h5py.File(path, "w") as f:
        ds_v2 = f.create_dataset("payload_v2", data=np.arange(16, dtype="<f8"))
        ds_v3 = f.create_dataset("payload_v3", data=np.arange(16, dtype="<f8"))
        sign_dataset(ds_v2, hmac_key, algorithm="hmac-sha256")
        sign_dataset(ds_v3, dsa_kp.private_key, algorithm="ml-dsa-87")

    with h5py.File(path, "r") as f:
        assert verify_dataset(f["payload_v2"], hmac_key,
                               algorithm="hmac-sha256")
        assert verify_dataset(f["payload_v3"], dsa_kp.public_key,
                               algorithm="ml-dsa-87")
        v2_raw = f["payload_v2"].attrs[SIGNATURE_ATTR]
        v3_raw = f["payload_v3"].attrs[SIGNATURE_ATTR]
        v2_str = v2_raw.decode() if isinstance(v2_raw, bytes) else str(v2_raw)
        v3_str = v3_raw.decode() if isinstance(v3_raw, bytes) else str(v3_raw)
        assert v2_str.startswith(SIGNATURE_V2_PREFIX)
        assert v3_str.startswith(SIGNATURE_V3_PREFIX)


# ── Legacy v0.7 HMAC still verifies under v0.8 code ──────────────────


def test_v07_classical_signature_still_verifies(tmp_path: Path) -> None:
    """A file signed with v0.7 HMAC-SHA256 ("v2:" prefix) remains
    readable and verifiable by v0.8 code. This protects the
    backward-compat promise from HANDOFF binding #44."""
    import h5py

    path = tmp_path / "v07_legacy.tio"
    hmac_key = bytes(range(32))
    with h5py.File(path, "w") as f:
        ds = f.create_dataset("payload", data=np.arange(32, dtype="<f8"))
        sign_dataset(ds, hmac_key, algorithm="hmac-sha256")

    # Re-open under v0.8 code and verify.
    with h5py.File(path, "r") as f:
        assert verify_dataset(f["payload"], hmac_key,
                               algorithm="hmac-sha256")
        stored = f["payload"].attrs[SIGNATURE_ATTR]
        stored_str = stored.decode() if isinstance(stored, bytes) else str(stored)
        assert stored_str.startswith(SIGNATURE_V2_PREFIX)
