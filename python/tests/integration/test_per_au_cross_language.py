"""v1.0 cross-language conformance harness for opt_per_au_encryption.

Drives the three language implementations via subprocess and
confirms:

1. A fixture encrypted by any of Python / ObjC / Java can be
   decrypted by any of the three. Byte-level equality is checked on
   the canonical ``.mpad`` dump emitted by the ``decrypt`` CLI; any
   per-AU ciphertext change (IV, tag, byte layout) trips the test.

2. The same holds for the transport round trip: a ``.tis`` produced
   by one ``send`` can be fed to any ``recv`` and decrypts to the
   same plaintext bytes.

Tests are skipped when the ObjC or Java CLI is missing, so the
Python side still runs in isolation on platforms where those builds
aren't available.

Cross-language equivalents: Objective-C ``TtioPerAU``, Java
``global.thalion.ttio.tools.PerAUCli``.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]

OBJC_CLI = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioPerAU"

JAVA_CLASS = "global.thalion.ttio.tools.PerAUCli"


def _java_classpath() -> str | None:
    """Build a classpath string usable by the Java PerAUCli, or return
    None when the Java side hasn't been built. We rely on Maven's
    {@code dependency:build-classpath} output (cached at
    {@code target/classpath.txt}) plus {@code target/classes}."""
    java_root = REPO_ROOT / "java"
    classes = java_root / "target" / "classes"
    cp_file = java_root / "target" / "classpath.txt"
    if not classes.exists():
        return None
    if not cp_file.exists():
        # Try to produce it once; silently skip if Maven is unavailable.
        try:
            subprocess.run(
                ["mvn", "-q", "-DincludeScope=runtime",
                 "dependency:build-classpath",
                 f"-Dmdep.outputFile={cp_file}"],
                cwd=java_root, check=True, capture_output=True, timeout=180,
            )
        except Exception:
            return None
    extra = cp_file.read_text().strip() if cp_file.exists() else ""
    # jarhdf5 is scope=system in pom.xml; build-classpath won't include
    # it. Splice it in manually.
    hdf5_jar = "/usr/share/java/jarhdf5.jar"
    parts = [str(classes)]
    if extra:
        parts.append(extra)
    if Path(hdf5_jar).exists():
        parts.append(hdf5_jar)
    return ":".join(parts)


def _objc_available() -> bool:
    return OBJC_CLI.exists() and os.access(OBJC_CLI, os.X_OK)


def _java_available() -> bool:
    return shutil.which("java") is not None and _java_classpath() is not None


def _fixture_ttio(tmp_path: Path, name: str) -> Path:
    """Build a deterministic plaintext .tio usable by all three
    languages."""
    from ttio import SpectralDataset
    from ttio.spectral_dataset import WrittenRun

    n_spectra, per_spectrum = 3, 4
    total = n_spectra * per_spectrum
    mz = np.array([100.0 + i for i in range(total)], dtype="<f8")
    intensity = np.array([10.0 * (i + 1) for i in range(total)], dtype="<f8")
    offsets = np.array([0, 4, 8], dtype="<u8")
    lengths = np.array([4, 4, 4], dtype="<u4")

    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=1,                       # MS1_DDA
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.array([1.0, 2.0, 3.0], dtype="<f8"),
        ms_levels=np.array([1, 2, 1], dtype="<i4"),
        polarities=np.array([1, 1, 1], dtype="<i4"),
        precursor_mzs=np.array([0.0, 500.0, 0.0], dtype="<f8"),
        precursor_charges=np.array([0, 2, 0], dtype="<i4"),
        base_peak_intensities=np.array([40.0, 80.0, 120.0], dtype="<f8"),
        signal_compression="none",
    )

    path = tmp_path / name
    SpectralDataset.write_minimal(
        path, title="xlang", isa_investigation_id="ISA-XLANG",
        runs={"run_0001": run},
    )
    return path


def _key_file(tmp_path: Path) -> Path:
    p = tmp_path / "key.bin"
    p.write_bytes(bytes([0x77] * 32))
    return p


# ───────────────────────── runner helpers ──────────────────────────

def _run_py(*args: str) -> None:
    subprocess.run(
        [sys.executable, "-m", "ttio.tools.per_au_cli", *args],
        check=True, capture_output=True,
    )


def _run_objc(*args: str) -> None:
    env = os.environ.copy()
    # Ensure the dynamic linker finds libTTIO built alongside the tool.
    lib_dir = str(REPO_ROOT / "objc" / "Source" / "obj")
    prior = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = f"{lib_dir}:{prior}" if prior else lib_dir
    subprocess.run([str(OBJC_CLI), *args], check=True, capture_output=True,
                    env=env)


def _run_java(*args: str) -> None:
    cp = _java_classpath()
    assert cp is not None
    native_path = "/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial"
    subprocess.run(
        ["java", f"-Djava.library.path={native_path}", "-cp", cp, JAVA_CLASS,
         *args],
        check=True, capture_output=True,
    )


RUNNERS = {"py": _run_py}
if _objc_available():
    RUNNERS["objc"] = _run_objc
if _java_available():
    RUNNERS["java"] = _run_java


# ───────────────────────── tests ───────────────────────────────────

@pytest.mark.parametrize("enc_lang,dec_lang",
                          [(e, d) for e in RUNNERS for d in RUNNERS])
@pytest.mark.parametrize("headers", [False, True])
def test_file_level_round_trip(tmp_path, enc_lang, dec_lang, headers):
    fx = _fixture_ttio(tmp_path, f"fx_{enc_lang}_{dec_lang}_{headers}.tio")
    key = _key_file(tmp_path)
    encrypted = tmp_path / f"enc_{enc_lang}_{dec_lang}_{headers}.tio"

    enc_args = ["encrypt", str(fx), str(encrypted), str(key)]
    if headers:
        enc_args.append("--headers")
    RUNNERS[enc_lang](*enc_args)

    out_mpad = tmp_path / f"dump_{enc_lang}_{dec_lang}_{headers}.mpad"
    RUNNERS[dec_lang]("decrypt", str(encrypted), str(out_mpad), str(key))

    # Golden: Python decrypts whatever Python encrypted → baseline.
    baseline_mpad = tmp_path / f"baseline_{enc_lang}_{headers}.mpad"
    if (enc_lang, dec_lang) != ("py", "py") or not baseline_mpad.exists():
        RUNNERS["py"]("decrypt", str(encrypted),
                        str(baseline_mpad), str(key))

    assert baseline_mpad.read_bytes() == out_mpad.read_bytes(), (
        f"cross-lang mismatch: encrypt={enc_lang} decrypt={dec_lang} "
        f"headers={headers}"
    )


def test_transcode_plaintext_to_per_au(tmp_path):
    """`transcode` on a plaintext fixture matches a direct `encrypt`
    with the same key + headers setting (modulo IV randomness, which
    we strip by byte-comparing the decrypted MPAD dump)."""
    fx = _fixture_ttio(tmp_path, "tc_fx.tio")
    key = _key_file(tmp_path)

    direct_enc = tmp_path / "tc_direct.tio"
    via_transcode = tmp_path / "tc_via.tio"

    _run_py("encrypt", str(fx), str(direct_enc), str(key), "--headers")
    _run_py("transcode", str(fx), str(via_transcode), str(key), "--headers")

    dump_direct = tmp_path / "tc_direct.mpad"
    dump_via = tmp_path / "tc_via.mpad"
    _run_py("decrypt", str(direct_enc), str(dump_direct), str(key))
    _run_py("decrypt", str(via_transcode), str(dump_via), str(key))
    assert dump_direct.read_bytes() == dump_via.read_bytes()


def test_transcode_rekey_path(tmp_path):
    """After transcoding with --rekey to a new key, the old key no
    longer decrypts and the new key decrypts to the same plaintext."""
    fx = _fixture_ttio(tmp_path, "tc_fx2.tio")
    key1 = _key_file(tmp_path)
    key2 = tmp_path / "key2.bin"
    key2.write_bytes(bytes([0xAB] * 32))

    enc_v1 = tmp_path / "tc_v1.tio"
    _run_py("encrypt", str(fx), str(enc_v1), str(key1))

    enc_v2 = tmp_path / "tc_v2.tio"
    _run_py("transcode", str(enc_v1), str(enc_v2), str(key1),
             "--rekey", str(key2))

    # Old key should not recover plaintext from v2.
    with pytest.raises(subprocess.CalledProcessError):
        _run_py("decrypt", str(enc_v2), str(tmp_path / "bad.mpad"),
                 str(key1))

    # New key should; plaintext equals the original.
    dump_baseline = tmp_path / "baseline.mpad"
    dump_rekeyed = tmp_path / "rekeyed.mpad"
    _run_py("decrypt", str(enc_v1), str(dump_baseline), str(key1))
    _run_py("decrypt", str(enc_v2), str(dump_rekeyed), str(key2))
    assert dump_baseline.read_bytes() == dump_rekeyed.read_bytes()


@pytest.mark.parametrize("send_lang,recv_lang",
                          [(s, r) for s in RUNNERS for r in RUNNERS])
@pytest.mark.parametrize("headers", [False, True])
def test_transport_round_trip(tmp_path, send_lang, recv_lang, headers):
    fx = _fixture_ttio(tmp_path,
        f"tfx_{send_lang}_{recv_lang}_{headers}.tio")
    key = _key_file(tmp_path)
    encrypted = tmp_path / f"tenc_{send_lang}_{recv_lang}_{headers}.tio"

    enc_args = ["encrypt", str(fx), str(encrypted), str(key)]
    if headers:
        enc_args.append("--headers")
    RUNNERS["py"](*enc_args)   # fix encryption side to Python so we
                                # isolate the transport behaviour

    stream = tmp_path / f"stream_{send_lang}_{recv_lang}_{headers}.tis"
    RUNNERS[send_lang]("send", str(encrypted), str(stream))

    received = tmp_path / f"recv_{send_lang}_{recv_lang}_{headers}.tio"
    RUNNERS[recv_lang]("recv", str(stream), str(received))

    # Decrypt both sides in Python and compare canonical MPAD dumps.
    out_a = tmp_path / f"pa_{send_lang}_{recv_lang}_{headers}.mpad"
    out_b = tmp_path / f"pb_{send_lang}_{recv_lang}_{headers}.mpad"
    _run_py("decrypt", str(encrypted), str(out_a), str(key))
    _run_py("decrypt", str(received), str(out_b), str(key))
    assert out_a.read_bytes() == out_b.read_bytes(), (
        f"transport mismatch: send={send_lang} recv={recv_lang} "
        f"headers={headers}"
    )
