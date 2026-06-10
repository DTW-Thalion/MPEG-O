#!/usr/bin/env python3
"""Generate cross-language ``dek_wrapped`` envelope-encryption fixtures.

Run from the repo root::

    python conformance/key_rotation/gen_fixtures.py

This drives each *available* language writer (Python always; Java and
ObjC when their CLIs are built) to produce a reference
envelope-encrypted ``.tio`` whose dataset-level DEK is wrapped under a
**fixed, committed KEK**. It writes, under
``conformance/key_rotation/``:

* ``kek_aes.bin`` — the fixed 32-byte AES-256-GCM KEK (committed).
* ``kek_mlkem_pub.bin`` / ``kek_mlkem_priv.bin`` — the fixed ML-KEM-1024
  keypair (committed) used for the PQC ``wrap`` (public) / ``unwrap``
  (private) paths.
* ``fixtures/<writer>_<alg>.tio`` — one reference file per writer ×
  algorithm.
* ``expected.json`` — for each fixture, the algorithm and the
  **expected plaintext DEK hex** the writer generated. The
  cross-language read tests unwrap each fixture with the committed KEK
  and assert byte-equality against this DEK.

The on-disk ``dek_wrapped`` dataset MUST be ``uint8[N]`` at the exact
blob length (71 bytes for AES-GCM, 1639 for ML-KEM). This is the bug
fixed on ``fix/dek-wrapped-xlang``: Java/ObjC formerly stored it as an
int32-padded dataset, corrupting Python/cross-language reads.

Coverage:
* **AES-256-GCM (71 bytes)** — full NxN over Python / Java / ObjC.
* **ML-KEM-1024 (1639 bytes)** — Python / ObjC only; the Java
  ``KeyRotationManager`` exposes no dataset-level PQC enable path.

Re-run this generator and review the diff to regenerate fixtures.
Because AES-GCM and ML-KEM ciphertexts embed fresh random IVs /
encapsulations, the ``.tio`` bytes are NOT reproducible run-to-run —
the committed contract is the *unwrappability* of each fixture to its
committed DEK, not byte-identity of the file.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
FIXTURES = HERE / "fixtures"

KEK_AES = HERE / "kek_aes.bin"
KEK_MLKEM_PUB = HERE / "kek_mlkem_pub.bin"
KEK_MLKEM_PRIV = HERE / "kek_mlkem_priv.bin"

# Fixed AES KEK: 32 bytes of 0x2b. Committed so every language wraps /
# unwraps under the identical key.
AES_KEK_BYTES = bytes([0x2B] * 32)


def _ensure_keys() -> bool:
    """Write the committed KEK material. Returns True if the PQC keypair
    is available (liboqs present), False otherwise."""
    KEK_AES.write_bytes(AES_KEK_BYTES)
    try:
        from ttio import pqc
        if not pqc.is_available():
            return False
        kp = pqc.kem_keygen()
        KEK_MLKEM_PUB.write_bytes(kp.public_key)
        KEK_MLKEM_PRIV.write_bytes(kp.private_key)
        return True
    except Exception:
        return False


# ── writer drivers ──────────────────────────────────────────────────

def _py_wrap(out_tio: Path, kek_file: Path, algorithm: str) -> str:
    res = subprocess.run(
        [sys.executable, "-m", "ttio.tools.dek_envelope_cli", "wrap",
         str(out_tio), str(kek_file), "--algorithm", algorithm],
        check=True, capture_output=True, text=True,
    )
    return res.stdout.strip()


def _java_classpath() -> str | None:
    java_root = REPO_ROOT / "java"
    classes = java_root / "target" / "classes"
    cp_file = java_root / "target" / "classpath.txt"
    if not classes.exists():
        return None
    if not cp_file.exists():
        try:
            subprocess.run(
                ["mvn", "-q", "-DincludeScope=runtime",
                 "dependency:build-classpath",
                 f"-Dmdep.outputFile={cp_file}"],
                cwd=java_root, check=True, capture_output=True, timeout=300,
            )
        except Exception:
            return None
    extra = cp_file.read_text().strip() if cp_file.exists() else ""
    hdf5_jar = "/usr/local/lib/jarhdf5.jar"
    parts = [str(classes)]
    if extra:
        parts.append(extra)
    if Path(hdf5_jar).exists():
        parts.append(hdf5_jar)
    return ":".join(parts)


_JAVA_FLAGS = [
    "--enable-preview",
    "--enable-native-access=ALL-UNNAMED",
    "-Djava.library.path=/usr/local/lib",
]


def _java_wrap(out_tio: Path, kek_file: Path, algorithm: str) -> str:
    cp = _java_classpath()
    assert cp is not None
    res = subprocess.run(
        ["java", *_JAVA_FLAGS, "-cp", cp,
         "global.thalion.ttio.tools.DekEnvelopeCli", "wrap",
         str(out_tio), str(kek_file), "--algorithm", algorithm],
        check=True, capture_output=True, text=True,
    )
    return res.stdout.strip()


_OBJC_CLI = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioDekEnvelope"


def _objc_env() -> dict:
    env = os.environ.copy()
    lib_dir = str(REPO_ROOT / "objc" / "Source" / "obj")
    prior = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = f"{lib_dir}:{prior}" if prior else lib_dir
    return env


def _objc_wrap(out_tio: Path, kek_file: Path, algorithm: str) -> str:
    res = subprocess.run(
        [str(_OBJC_CLI), "wrap", str(out_tio), str(kek_file),
         "--algorithm", algorithm],
        check=True, capture_output=True, text=True, env=_objc_env(),
    )
    return res.stdout.strip()


def main() -> int:
    pqc_ok = _ensure_keys()
    if FIXTURES.exists():
        shutil.rmtree(FIXTURES)
    FIXTURES.mkdir(parents=True)

    writers: dict[str, callable] = {"py": _py_wrap}
    if _java_classpath() is not None and shutil.which("java"):
        writers["java"] = _java_wrap
    if _OBJC_CLI.exists() and os.access(_OBJC_CLI, os.X_OK):
        writers["objc"] = _objc_wrap

    # algorithm -> (kek file for WRITING, writer langs)
    plans = [("aes-256-gcm", KEK_AES, list(writers))]
    if pqc_ok:
        # Java has no dataset-level PQC enable path; cover py/objc only.
        pqc_writers = [w for w in ("py", "objc") if w in writers]
        plans.append(("ml-kem-1024", KEK_MLKEM_PUB, pqc_writers))

    manifest: dict = {
        "_comment": "Cross-language dek_wrapped envelope-encryption "
                    "fixtures. Each fixture's /protection/key_info/"
                    "dek_wrapped is uint8[N] at the exact blob length "
                    "(71 AES-GCM, 1639 ML-KEM). The read tests unwrap "
                    "with the committed KEK and assert the recovered DEK "
                    "equals expected_dek_hex. Generated by gen_fixtures.py; "
                    "do not hand-edit.",
        "kek_aes_file": "kek_aes.bin",
        "kek_mlkem_pub_file": "kek_mlkem_pub.bin",
        "kek_mlkem_priv_file": "kek_mlkem_priv.bin",
        "blob_lengths": {"aes-256-gcm": 71, "ml-kem-1024": 1639},
        "fixtures": [],
    }

    for algorithm, kek_file, langs in plans:
        alg_tag = "aes" if algorithm == "aes-256-gcm" else "mlkem"
        for lang in langs:
            name = f"{lang}_{alg_tag}.tio"
            out_tio = FIXTURES / name
            dek_hex = writers[lang](out_tio, kek_file, algorithm)
            assert len(dek_hex) == 64, f"{name}: bad DEK hex {dek_hex!r}"
            manifest["fixtures"].append({
                "fixture": name,
                "writer": lang,
                "algorithm": algorithm,
                "expected_dek_hex": dek_hex,
            })
            print(f"wrote {name} (writer={lang} alg={algorithm} "
                  f"dek={dek_hex[:8]}...)")

    (HERE / "expected.json").write_text(
        json.dumps(manifest, indent=2) + "\n")
    print(f"wrote expected.json ({len(manifest['fixtures'])} fixtures); "
          f"pqc={'yes' if pqc_ok else 'no'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
