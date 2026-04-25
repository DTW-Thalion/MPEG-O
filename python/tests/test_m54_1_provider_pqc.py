"""Milestone 54.1 — provider × PQC cross-language matrix extension.

M54 shipped the 20 core HDF5 / primitive cross-language cells. This
follow-up extends coverage to the ZarrProvider and SqliteProvider
surfaces, closing the "v3 signature on Zarr" and "v3 signature on
SQLite" rows of HANDOFF.md's M54 acceptance matrix.

Cells (parametrised across provider × signer × verifier):

* ZarrProvider  × (Python ↔ Java ↔ ObjC) = 6 cells
* SqliteProvider × (Python ↔ Java ↔ ObjC) = 6 cells

Same fixture-exchange pattern as M54: one language signs the dataset
(storing ``v3:<base64>`` on ``@ttio_signature``), another language
opens the same store and verifies.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from ttio import pqc
from ttio.providers.sqlite import SqliteProvider
from ttio.providers.zarr import ZarrProvider
from ttio.signatures import (
    SIGNATURE_ATTR,
    SIGNATURE_V3_PREFIX,
    sign_storage_dataset,
    verify_storage_dataset,
)

_REPO_ROOT = Path(__file__).resolve().parents[2]


def _java_cli() -> list[str] | None:
    runner = _REPO_ROOT / "java" / "run-tool.sh"
    classes = _REPO_ROOT / "java" / "target" / "classes"
    if not runner.is_file() or not os.access(runner, os.X_OK):
        return None
    if not classes.is_dir():
        return None
    return [str(runner), "com.dtwthalion.ttio.tools.PQCTool"]


def _objc_cli() -> list[str] | None:
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


JAVA_CMD = _java_cli()
OBJC_CMD = _objc_cli()

skip_no_java = pytest.mark.skipif(
    JAVA_CMD is None or not pqc.is_available(),
    reason="java/run-tool.sh or target/classes missing",
)
skip_no_objc = pytest.mark.skipif(
    OBJC_CMD is None or not pqc.is_available(),
    reason="objc/Tools/obj/TtioPQCTool missing",
)


def _run(cmd: list[str], env: dict[str, str] | None = None) -> int:
    proc = subprocess.run(cmd, capture_output=True, env=env)
    if proc.returncode not in (0, 1):
        sys.stderr.write(
            f"CLI failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"  stdout: {proc.stdout.decode(errors='replace')[:400]}\n"
            f"  stderr: {proc.stderr.decode(errors='replace')[:400]}\n")
    return proc.returncode


def _provider_sign_cli(cli: list[str], url: str, ds_path: str,
                         sk_path: Path,
                         env: dict[str, str] | None = None) -> int:
    return _run(cli + ["provider-sign", url, ds_path, str(sk_path)], env=env)


def _provider_verify_cli(cli: list[str], url: str, ds_path: str,
                           pk_path: Path,
                           env: dict[str, str] | None = None) -> int:
    return _run(cli + ["provider-verify", url, ds_path, str(pk_path)], env=env)


# ── Fixture setup ────────────────────────────────────────────────────


def _seed_provider(url: str):
    """Open the provider for ``url`` in CREATE mode, write a stable
    float64 dataset named /payload, close. Returns the provider
    handle so the caller can reopen."""
    if url.startswith("zarr:"):
        p = ZarrProvider()
        p.open(url, mode="w")
    elif url.startswith("sqlite:"):
        p = SqliteProvider()
        p.open(url, mode="w")
    else:
        raise ValueError(f"unknown provider url: {url}")
    root = p.root_group()
    from ttio.enums import Precision, Compression
    ds = root.create_dataset("payload", precision=Precision.FLOAT64,
                              length=64, chunk_size=0,
                              compression=Compression.NONE)
    data = np.arange(64, dtype="<f8")
    ds.write(data)
    p.close()


def _open_ro(url: str):
    if url.startswith("zarr:"):
        p = ZarrProvider()
        p.open(url, mode="r")
        return p
    if url.startswith("sqlite:"):
        p = SqliteProvider()
        p.open(url, mode="r")
        return p
    raise ValueError(f"unknown provider url: {url}")


def _open_rw(url: str):
    if url.startswith("zarr:"):
        p = ZarrProvider()
        p.open(url, mode="r+")
        return p
    if url.startswith("sqlite:"):
        p = SqliteProvider()
        p.open(url, mode="r+")
        return p
    raise ValueError(f"unknown provider url: {url}")


# ── Provider × cross-language matrix ─────────────────────────────────


def _provider_url(provider: str, tmp_path: Path) -> str:
    # tmp_path is absolute (starts with /), so zarr://{abs} already
    # yields three slashes (zarr:// + /tmp/...).
    if provider == "zarr":
        return f"zarr://{tmp_path / 'store.zarr'}"
    if provider == "sqlite":
        return f"sqlite://{tmp_path / 'store.db'}"
    raise ValueError(provider)


@pytest.mark.parametrize("provider", ["zarr", "sqlite"])
@pytest.mark.parametrize("signer,verifier", [
    pytest.param("python", "java",   marks=skip_no_java,
                  id="python-to-java"),
    pytest.param("python", "objc",   marks=skip_no_objc,
                  id="python-to-objc"),
    pytest.param("java",   "python", marks=skip_no_java,
                  id="java-to-python"),
    pytest.param("java",   "objc",   marks=[skip_no_java, skip_no_objc],
                  id="java-to-objc"),
    pytest.param("objc",   "python", marks=skip_no_objc,
                  id="objc-to-python"),
    pytest.param("objc",   "java",   marks=[skip_no_objc, skip_no_java],
                  id="objc-to-java"),
])
def test_v3_provider_cross_language(tmp_path: Path, provider: str,
                                      signer: str, verifier: str) -> None:
    """Matrix cell: signer writes a ``v3:`` ML-DSA-87 signature onto
    the provider-backed dataset; verifier opens the same store and
    validates."""
    pk_path = tmp_path / "pk.bin"
    sk_path = tmp_path / "sk.bin"

    kp = pqc.sig_keygen()
    pk_path.write_bytes(kp.public_key)
    sk_path.write_bytes(kp.private_key)

    url = _provider_url(provider, tmp_path)
    _seed_provider(url)

    # Sign.
    if signer == "python":
        p = _open_rw(url)
        try:
            ds = p.root_group().open_dataset("payload")
            sign_storage_dataset(ds, kp.private_key, algorithm="ml-dsa-87")
        finally:
            p.close()
    else:
        cli = JAVA_CMD if signer == "java" else OBJC_CMD
        env = _objc_env() if signer == "objc" else None
        rc = _provider_sign_cli(cli, url, "/payload", sk_path, env=env)
        assert rc == 0, f"{signer} provider-sign failed on {provider}"

    # Sanity: the stored attribute starts with "v3:".
    p = _open_ro(url)
    try:
        ds = p.root_group().open_dataset("payload")
        stored = ds.get_attribute(SIGNATURE_ATTR)
        if isinstance(stored, bytes):
            stored = stored.decode()
        assert str(stored).startswith(SIGNATURE_V3_PREFIX), \
            f"expected v3: prefix on {provider} store, got {stored!r}"
    finally:
        p.close()

    # Verify.
    if verifier == "python":
        p = _open_ro(url)
        try:
            ds = p.root_group().open_dataset("payload")
            assert verify_storage_dataset(
                ds, kp.public_key, algorithm="ml-dsa-87")
        finally:
            p.close()
    else:
        cli = JAVA_CMD if verifier == "java" else OBJC_CMD
        env = _objc_env() if verifier == "objc" else None
        rc = _provider_verify_cli(cli, url, "/payload", pk_path, env=env)
        assert rc == 0, f"{verifier} provider-verify failed on {provider}"
