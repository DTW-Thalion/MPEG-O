"""ref_diff v2 cross-language byte-equality matrix (Python <-> Java <-> ObjC).

Layer 3 cross-language gate per spec section 9.3. For each of 4 corpora,
encode the same input via Python (in-process ctypes), Java
(RefDiffV2Cli subprocess), and ObjC (TtioRefDiffV2Cli subprocess).
All three outputs must be byte-identical refdiff_v2 blobs.

Each language wraps the same deterministic ttio_ref_diff_v2_encode C
function (Python via ctypes, Java via JNI, ObjC by linking
libttio_rans), so results MUST agree.

Tagged ``integration``; deselected by default. Run with
``pytest -m integration``.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import ref_diff_v2 as rdv2

REPO = Path("/home/toddw/TTI-O")
NATIVE_LIB_DIR = REPO / "native" / "_build"
JAVA_JAR = REPO / "java" / "target" / "ttio-1.2.0.jar"
OBJC_CLI = REPO / "objc" / "Tools" / "obj" / "TtioRefDiffV2Cli"
REFERENCE_FASTA = REPO / "data" / "genomic" / "reference" / "hs37.chr22.fa"

CORPORA = [
    ("chr22",          REPO / "data/genomic/na12878/na12878.chr22.lean.mapped.bam"),
    ("wes",            REPO / "data/genomic/na12878_wes/na12878_wes.chr22.bam"),
    ("hg002_illumina", REPO / "data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam"),
    ("hg002_pacbio",   REPO / "data/genomic/hg002_pacbio/hg002_pacbio.subset.bam"),
]

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not rdv2.HAVE_NATIVE_LIB, reason="needs libttio_rans"),
    pytest.mark.skipif(not JAVA_JAR.exists(),
                       reason=f"Java jar not built at {JAVA_JAR}"),
    pytest.mark.skipif(not OBJC_CLI.exists(),
                       reason=f"ObjC TtioRefDiffV2Cli not built at {OBJC_CLI}"),
    pytest.mark.skipif(not REFERENCE_FASTA.exists(),
                       reason=f"chr22 reference not on disk: {REFERENCE_FASTA}"),
]


from ._mate_info_corpus import (
    extract_sequences_for_ref_diff,
    load_chr22_reference,
)


def _write_bin_inputs(tmp_path: Path, name: str,
                      sequences, offsets, positions, cigars,
                      reference, reference_md5, reference_uri):
    """Write 7 input files matching Java/ObjC CLI expectations."""
    files = {
        "sequences":     tmp_path / f"{name}_sequences.bin",
        "offsets":       tmp_path / f"{name}_offsets.bin",
        "positions":     tmp_path / f"{name}_positions.bin",
        "cigars":        tmp_path / f"{name}_cigars.txt",
        "reference":     tmp_path / f"{name}_reference.bin",
        "reference_md5": tmp_path / f"{name}_reference_md5.bin",
        "reference_uri": tmp_path / f"{name}_reference_uri.txt",
    }
    files["sequences"].write_bytes(bytes(sequences))
    np.ascontiguousarray(offsets, dtype="<u8").tofile(str(files["offsets"]))
    np.ascontiguousarray(positions, dtype="<i8").tofile(str(files["positions"]))
    files["cigars"].write_text("\n".join(cigars))
    files["reference"].write_bytes(reference)
    files["reference_md5"].write_bytes(reference_md5)
    files["reference_uri"].write_text(reference_uri)
    return files


@pytest.mark.parametrize("name,bam_path", CORPORA, ids=[c[0] for c in CORPORA])
def test_ref_diff_v2_cross_language_byte_equal(tmp_path, name, bam_path):
    if not bam_path.exists():
        pytest.skip(f"corpus not present: {bam_path}")

    # Step 1: Extract via canonical Python helper.
    seq, off, pos, cigars = extract_sequences_for_ref_diff(bam_path)
    n = pos.shape[0]
    if n == 0:
        pytest.skip(f"corpus has no mapped reads: {bam_path}")

    reference = load_chr22_reference(REFERENCE_FASTA)
    md5 = hashlib.md5(reference).digest()

    # Step 2: Encode via Python in-process.
    py_blob = rdv2.encode(seq, off, pos, cigars, reference, md5,
                          reference_uri=name)

    # Step 3: Write the input files for Java + ObjC.
    files = _write_bin_inputs(tmp_path, name, seq, off, pos, cigars,
                              reference, md5, name)

    # Step 4: Java CLI subprocess (direct java, NOT mvn exec).
    java_out = tmp_path / f"{name}_java.bin"
    java_proc = subprocess.run(
        ["java",
         f"-Djava.library.path={NATIVE_LIB_DIR}",
         "-cp", str(JAVA_JAR),
         "global.thalion.ttio.tools.RefDiffV2Cli",
         str(files["sequences"]), str(files["offsets"]), str(files["positions"]),
         str(files["cigars"]), str(files["reference"]), str(files["reference_md5"]),
         str(files["reference_uri"]), str(java_out)],
        capture_output=True, text=True,
    )
    assert java_proc.returncode == 0, (
        "{}: Java RefDiffV2Cli failed (rc={})\nstderr: {}".format(
            name, java_proc.returncode, java_proc.stderr))
    java_blob = java_out.read_bytes()

    # Step 5: ObjC CLI subprocess.
    objc_out = tmp_path / f"{name}_objc.bin"
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = (
        "{}:{}/objc/Source/obj:{}".format(
            NATIVE_LIB_DIR, REPO, env.get("LD_LIBRARY_PATH", ""))
    )
    objc_proc = subprocess.run(
        [str(OBJC_CLI),
         str(files["sequences"]), str(files["offsets"]), str(files["positions"]),
         str(files["cigars"]), str(files["reference"]), str(files["reference_md5"]),
         str(files["reference_uri"]), str(objc_out)],
        capture_output=True, text=True, env=env,
    )
    assert objc_proc.returncode == 0, (
        "{}: ObjC TtioRefDiffV2Cli failed (rc={})\nstderr: {}".format(
            name, objc_proc.returncode, objc_proc.stderr))
    objc_blob = objc_out.read_bytes()

    # Step 6: Three-way byte-equality check.
    py_hash = hashlib.sha256(py_blob).hexdigest()
    java_hash = hashlib.sha256(java_blob).hexdigest()
    objc_hash = hashlib.sha256(objc_blob).hexdigest()

    print("\n{}: n={:,}, encoded={:,} bytes".format(name, n, len(py_blob)))
    print("  Python:  sha256={}...".format(py_hash[:16]))
    print("  Java:    sha256={}...".format(java_hash[:16]))
    print("  ObjC:    sha256={}...".format(objc_hash[:16]))

    assert py_hash == java_hash, (
        "{}: Python vs Java diverge -- first diff at byte {}".format(
            name,
            next((i for i, (a, b) in enumerate(zip(py_blob, java_blob)) if a != b), -1)))
    assert py_hash == objc_hash, (
        "{}: Python vs ObjC diverge -- first diff at byte {}".format(
            name,
            next((i for i, (a, b) in enumerate(zip(py_blob, objc_blob)) if a != b), -1)))
    assert len(py_blob) == len(java_blob) == len(objc_blob)
