"""Cross-language byte-equality conformance for FASTA + FASTQ I/O.

For a fixed input fixture, all three implementations (Python, Java,
ObjC) read it via their FASTA/FASTQ reader, then write it back via
their FASTA/FASTQ writer. The three output files must be
byte-identical.

The test SKIPs if a per-language toolchain is unavailable (no JDK,
no built ObjC binary, no native rANS lib).
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from ttio.exporters.fasta import FastaWriter
from ttio.exporters.fastq import FastqWriter
from ttio.importers.fasta import FastaReader
from ttio.importers.fastq import FastqReader


REPO_ROOT = Path(__file__).resolve().parents[3]
JAVA_TARGET = REPO_ROOT / "java" / "target"
OBJC_TOOL_FASTA = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioFastaRoundTrip"
OBJC_TOOL_FASTQ = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioFastqRoundTrip"
OBJC_LIB_DIR = REPO_ROOT / "objc" / "Source" / "obj"


def _have_java() -> bool:
    if shutil.which("java") is None:
        return False
    classes = JAVA_TARGET / "classes"
    return classes.exists() and any(classes.rglob("FastaRoundTrip.class"))


def _have_objc_fasta() -> bool:
    return OBJC_TOOL_FASTA.exists() and os.access(OBJC_TOOL_FASTA, os.X_OK)


def _have_objc_fastq() -> bool:
    return OBJC_TOOL_FASTQ.exists() and os.access(OBJC_TOOL_FASTQ, os.X_OK)


def _java_classpath() -> str:
    """Return a classpath that resolves the FastaRoundTrip CLI plus
    the built libttio classes."""
    classes = JAVA_TARGET / "classes"
    return str(classes)


def _run_objc(tool: Path, in_path: Path, out_path: Path,
              extra: list[str] | None = None) -> None:
    cmd = [str(tool), str(in_path), str(out_path)]
    if extra:
        cmd.extend(extra)
    env = os.environ.copy()
    existing = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = (
        str(OBJC_LIB_DIR) + (":" + existing if existing else "")
    )
    res = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(
            f"ObjC tool {tool.name} failed (exit {res.returncode}): "
            f"{res.stderr.strip()}"
        )


def _run_java(klass: str, in_path: Path, out_path: Path,
              extra: list[str] | None = None) -> None:
    cmd = ["java", "-cp", _java_classpath(), klass, str(in_path), str(out_path)]
    if extra:
        cmd.extend(extra)
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(
            f"Java tool {klass} failed (exit {res.returncode}): "
            f"{res.stderr.strip()}"
        )


# ---------------------------------------------------------------------- FASTA


@pytest.mark.skipif(
    not (_have_java() and _have_objc_fasta()),
    reason="needs both Java classes and the built TtioFastaRoundTrip"
)
def test_fasta_three_way_byte_equal(tmp_path: Path) -> None:
    src = tmp_path / "src.fa"
    src.write_bytes(
        b">chr1\nACGTACGTACGT\n>chr2\nGGGggg\n>chr3\n"
        + b"A" * 125 + b"\n"
    )

    py_out = tmp_path / "py.fa"
    java_out = tmp_path / "java.fa"
    objc_out = tmp_path / "objc.fa"

    # Python round-trip
    ref = FastaReader(src).read_reference()
    FastaWriter.write_reference(ref, py_out, line_width=60, write_fai=True)

    _run_java("global.thalion.ttio.tools.FastaRoundTrip", src, java_out, ["60"])
    _run_objc(OBJC_TOOL_FASTA, src, objc_out, ["60"])

    py_bytes = py_out.read_bytes()
    java_bytes = java_out.read_bytes()
    objc_bytes = objc_out.read_bytes()

    assert py_bytes == java_bytes, (
        f"Python vs Java FASTA mismatch:\nPY:   {py_bytes[:200]!r}\n"
        f"JAVA: {java_bytes[:200]!r}"
    )
    assert py_bytes == objc_bytes, (
        f"Python vs ObjC FASTA mismatch:\nPY:   {py_bytes[:200]!r}\n"
        f"OBJC: {objc_bytes[:200]!r}"
    )

    # And .fai indices must match too.
    py_fai = (tmp_path / "py.fa.fai").read_text()
    java_fai = (tmp_path / "java.fa.fai").read_text()
    objc_fai = (tmp_path / "objc.fa.fai").read_text()
    assert py_fai == java_fai
    assert py_fai == objc_fai


# ---------------------------------------------------------------------- FASTQ


@pytest.mark.skipif(
    not (_have_java() and _have_objc_fastq()),
    reason="needs both Java classes and the built TtioFastqRoundTrip"
)
def test_fastq_three_way_byte_equal(tmp_path: Path) -> None:
    src = tmp_path / "src.fq"
    src.write_bytes(
        b"@r1\nACGTACGT\n+\n!!!!!!!!\n"
        b"@r2\nGGGGAAAA\n+\nIIIIJJJJ\n"
        b"@r3\nNNNN\n+\n????\n"
    )

    py_out = tmp_path / "py.fq"
    java_out = tmp_path / "java.fq"
    objc_out = tmp_path / "objc.fq"

    run = FastqReader(src).read()
    FastqWriter.write(run, py_out)

    _run_java("global.thalion.ttio.tools.FastqRoundTrip", src, java_out)
    _run_objc(OBJC_TOOL_FASTQ, src, objc_out)

    py_bytes = py_out.read_bytes()
    java_bytes = java_out.read_bytes()
    objc_bytes = objc_out.read_bytes()

    assert py_bytes == java_bytes, (
        f"Python vs Java FASTQ mismatch:\nPY:   {py_bytes[:200]!r}\n"
        f"JAVA: {java_bytes[:200]!r}"
    )
    assert py_bytes == objc_bytes, (
        f"Python vs ObjC FASTQ mismatch:\nPY:   {py_bytes[:200]!r}\n"
        f"OBJC: {objc_bytes[:200]!r}"
    )
    # And the round-trip preserves the source bytes.
    assert py_bytes == src.read_bytes()
