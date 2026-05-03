"""M90.6: cross-language conformance for genomic per-AU encryption.

Each language's per_au_cli encrypts a deterministic genomic source
.tio with a known key. Python's in-memory decrypt_per_au_file then
materialises the encrypted file and confirms the per-base sequences
and qualities round-trip byte-exactly to the original input. This
proves on-disk wire compatibility for the M90.1 genomic encryption
across Python, ObjC, and Java.

The full 3x3 matrix (each language decrypts each language's output
to byte-equal MPAD dumps) is intentionally deferred — the existing
MPAD format in per_au_cli casts every channel to float64, which
mangles uint8 genomic channels. Adding a uint8-aware MPAD subformat
to all three CLIs is a follow-up scope; the current 3-cell harness
validates the strongest correctness property (each language's
encryption is byte-readable by the trusted Python reference reader).

Skip rules: missing ObjC binary or Java classpath skips that cell
rather than failing.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")

from ttio import SpectralDataset
from ttio.encryption_per_au import decrypt_per_au_file
from ttio.written_genomic_run import WrittenGenomicRun


REPO_ROOT = Path(__file__).resolve().parents[3]
OBJC_CLI = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioPerAU"
JAVA_CLASS = "global.thalion.ttio.tools.PerAUCli"


def _objc_available() -> bool:
    return OBJC_CLI.is_file() and (REPO_ROOT / "objc" / "Source" / "obj").is_dir()


def _java_classpath() -> str | None:
    java_root = REPO_ROOT / "java"
    classes = java_root / "target" / "classes"
    cp_file = java_root / "target" / "classpath.txt"
    if not classes.exists():
        return None
    if not cp_file.exists():
        try:
            subprocess.run(
                ["mvn", "-q", "dependency:build-classpath",
                 "-DincludeScope=test",
                 f"-Dmdep.outputFile={cp_file}"],
                cwd=str(java_root), check=True, timeout=120,
            )
        except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return None
    if not cp_file.exists():
        return None
    cp = cp_file.read_text().strip()
    # HDF5 is declared as a 'system' scope dependency in pom.xml
    # (jhdf5 → /usr/share/java/jarhdf5.jar), which mvn
    # dependency:build-classpath -DincludeScope=test does NOT emit.
    # Append it explicitly so PerAUCli + writers can load
    # hdf.hdf5lib.* classes at runtime.
    hdf5_jar = "/usr/share/java/jarhdf5.jar"
    if Path(hdf5_jar).exists():
        cp = f"{cp}:{hdf5_jar}"
    return f"{classes}:{cp}"


# ───────────────────────── source fixture ──────────────────────────

# Deterministic genomic-only fixture used by every cell. 3 reads,
# 8 bases each, distinct quality per read so a per-AU mixup
# would be visible in the verifier.
_FIXTURE_CHROMOSOMES = ["chr1", "chr1", "chr2"]
_FIXTURE_POSITIONS = [100, 200, 300]
_FIXTURE_FLAGS = [0x0003, 0x0003, 0x0003]
_FIXTURE_MAPQS = [60, 55, 40]
_FIXTURE_SEQUENCE = b"ACGTACGT"  # 8 bases per read
_FIXTURE_READ_LEN = 8


def _build_source_tio(path: Path) -> Path:
    n_reads = len(_FIXTURE_CHROMOSOMES)
    sequences = np.frombuffer(
        _FIXTURE_SEQUENCE * n_reads, dtype=np.uint8,
    )
    qualities_concat = bytes()
    for i in range(n_reads):
        qualities_concat += bytes([20 + i] * _FIXTURE_READ_LEN)
    qualities = np.frombuffer(qualities_concat, dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array(_FIXTURE_POSITIONS, dtype=np.int64),
        mapping_qualities=np.array(_FIXTURE_MAPQS, dtype=np.uint8),
        flags=np.array(_FIXTURE_FLAGS, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n_reads, dtype=np.uint64) * _FIXTURE_READ_LEN,
        lengths=np.full(n_reads, _FIXTURE_READ_LEN, dtype=np.uint32),
        cigars=[f"{_FIXTURE_READ_LEN}M"] * n_reads,
        read_names=[f"read_{i:03d}" for i in range(n_reads)],
        mate_chromosomes=[""] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=list(_FIXTURE_CHROMOSOMES),
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.6 genomic xlang fixture",
        isa_investigation_id="ISA-M90-XLANG",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


def _key_file(tmp_path: Path) -> Path:
    p = tmp_path / "key.bin"
    p.write_bytes(bytes([0x77] * 32))
    return p


# ───────────────────────── encrypt CLI runners ─────────────────────


def _encrypt_python(src_tio: Path, dst_tio: Path, key: Path) -> None:
    proc = subprocess.run(
        [sys.executable, "-m", "ttio.tools.per_au_cli",
         "encrypt", str(src_tio), str(dst_tio), str(key)],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"python per_au_cli encrypt exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


def _encrypt_objc(src_tio: Path, dst_tio: Path, key: Path) -> None:
    if not _objc_available():
        pytest.skip("ObjC TtioPerAU binary not built")
    env = os.environ.copy()
    libdir = str(REPO_ROOT / "objc" / "Source" / "obj")
    env["LD_LIBRARY_PATH"] = (
        f"{libdir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    )
    proc = subprocess.run(
        [str(OBJC_CLI), "encrypt", str(src_tio), str(dst_tio), str(key)],
        capture_output=True, text=True, env=env, timeout=120,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"ObjC TtioPerAU encrypt exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


def _encrypt_java(src_tio: Path, dst_tio: Path, key: Path) -> None:
    cp = _java_classpath()
    if cp is None:
        pytest.skip("Java classpath not available")
    native_path = "/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial"
    proc = subprocess.run(
        ["java", f"-Djava.library.path={native_path}", "-cp", cp,
         JAVA_CLASS, "encrypt",
         str(src_tio), str(dst_tio), str(key)],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        pytest.fail(
            f"Java PerAUCli encrypt exit {proc.returncode}: "
            f"{proc.stderr.strip()}"
        )


_WRITERS = {
    "python": _encrypt_python,
    "objc":   _encrypt_objc,
    "java":   _encrypt_java,
}


# ───────────────────────── verification ────────────────────────────


def _verify_round_trip(encrypted_tio: Path, key: bytes) -> None:
    """Use Python's in-memory decrypt_per_au_file as the trusted
    cross-language reference reader. Asserts byte-exact recovery
    of the per-base sequences and qualities."""
    plain = decrypt_per_au_file(str(encrypted_tio), key)
    assert "genomic_0001" in plain, (
        f"genomic_0001 missing; got runs: {sorted(plain.keys())}"
    )
    g = plain["genomic_0001"]
    expected_seqs = _FIXTURE_SEQUENCE * len(_FIXTURE_CHROMOSOMES)
    assert g["sequences"].tobytes() == expected_seqs, (
        "sequences mismatch after decrypt"
    )
    expected_quals = bytes()
    for i in range(len(_FIXTURE_CHROMOSOMES)):
        expected_quals += bytes([20 + i] * _FIXTURE_READ_LEN)
    assert g["qualities"].tobytes() == expected_quals, (
        "qualities mismatch after decrypt"
    )


# ───────────────────────── matrix ──────────────────────────────────


@pytest.mark.parametrize("writer", list(_WRITERS),
                          ids=[f"{w}-encrypt" for w in _WRITERS])
def test_m90_genomic_encrypt_python_verify(writer: str, tmp_path: Path) -> None:
    """Each writer language encrypts the source genomic .tio; Python
    decrypts and verifies byte-exact recovery."""
    src = _build_source_tio(tmp_path / "source.tio")
    encrypted = tmp_path / f"{writer}_enc.tio"
    shutil.copyfile(src, encrypted)
    key_path = _key_file(tmp_path)
    _WRITERS[writer](src, encrypted, key_path)
    _verify_round_trip(encrypted, key_path.read_bytes())
