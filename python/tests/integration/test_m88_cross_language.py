"""M88 cross-language conformance harness for the SAM/BAM/CRAM importer.

Drives the three language implementations via subprocess against the
M88 BAM fixture (``m88_test.bam`` — 5 reads, 2 chromosomes, multi-RG,
exercises the mate-collapse and PNEXT mapping paths added in M88) and
confirms each emits byte-identical canonical JSON. Any divergence in
SAM parsing, RNEXT expansion, 1-based position handling, or
canonical-JSON serialisation trips the test.

Scope: this harness covers the BAM read path. CRAM read parity across
languages is verified implicitly — all three implementations consume
the same canonical M88 CRAM fixture in their own unit suites and
produce buffer-byte-identical decoded ``WrittenGenomicRun`` instances
(BAM-CRAM round-trip tests, M88 #6/#9/#10). A CRAM-aware dump CLI
across all three languages is deferred to M88.1.

The Python ``bam_dump`` CLI is the reference. ObjC's
``TtioBamDump`` and Java's ``BamDump`` must produce
byte-identical output when fed the M88 BAM fixture.

Tests are skipped when:
- ``samtools`` is missing from PATH (M88 dispatch requires it).
- The ObjC ``TtioBamDump`` binary or Java ``BamDump`` class is
  not built — the Python side still runs in isolation.

Cross-language equivalents: Objective-C ``TtioBamDump``, Java
``global.thalion.ttio.importers.BamDump``.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE = REPO_ROOT / "python" / "tests" / "fixtures" / "genomic" / "m88_test.bam"

OBJC_BIN = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioBamDump"
JAVA_POM = REPO_ROOT / "java" / "pom.xml"


def _samtools_available() -> bool:
    if shutil.which("samtools") is None:
        return False
    try:
        result = subprocess.run(
            ["samtools", "--version"],
            capture_output=True,
            timeout=5,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


pytestmark = pytest.mark.skipif(
    not _samtools_available(), reason="samtools not on PATH"
)


def _python_dump() -> str:
    """Run the Python bam_dump CLI against the M88 BAM and return canonical JSON."""
    result = subprocess.run(
        ["python3", "-m", "ttio.importers.bam_dump", str(FIXTURE)],
        cwd=str(REPO_ROOT / "python"),
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    return result.stdout


def _objc_dump() -> str:
    """Run the ObjC TtioBamDump CLI against the M88 BAM and return canonical JSON."""
    if not OBJC_BIN.exists():
        pytest.skip(f"ObjC TtioBamDump not built at {OBJC_BIN}")
    objc_source_obj = REPO_ROOT / "objc" / "Source" / "obj"
    env = {"LD_LIBRARY_PATH": str(objc_source_obj)}
    result = subprocess.run(
        [str(OBJC_BIN), str(FIXTURE)],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
        env={**env, "PATH": "/usr/bin:/usr/local/bin"},
    )
    return result.stdout


def _java_dump() -> str:
    """Run the Java BamDump CLI against the M88 BAM via Maven exec."""
    if not JAVA_POM.exists():
        pytest.skip(f"Java pom.xml not at {JAVA_POM}")
    result = subprocess.run(
        [
            "mvn", "-o", "-q", "exec:java",
            "-Dexec.mainClass=global.thalion.ttio.importers.BamDump",
            f"-Dexec.args={FIXTURE}",
        ],
        cwd=str(REPO_ROOT / "java"),
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    )
    return result.stdout


def test_python_dump_works():
    """Sanity: Python CLI produces non-empty canonical JSON for M88 fixture."""
    out = _python_dump()
    assert out.startswith("{")
    assert '"read_count": 5' in out
    assert '"sample_name": "M88_TEST_SAMPLE"' in out


def test_objc_matches_python_byte_exact():
    """ObjC TtioBamDump output is byte-identical to Python bam_dump on M88 fixture."""
    py = _python_dump()
    oc = _objc_dump()
    assert oc == py, f"ObjC diverges from Python:\n--- python:\n{py}\n--- objc:\n{oc}"


def test_java_matches_python_byte_exact():
    """Java BamDump output is byte-identical to Python bam_dump on M88 fixture."""
    py = _python_dump()
    ja = _java_dump()
    assert ja == py, f"Java diverges from Python:\n--- python:\n{py}\n--- java:\n{ja}"
