"""mate_info v2 cross-language byte-equality matrix (Python <-> Java <-> ObjC).

Layer 3 cross-language gate per spec section 9.3. For each of 4 corpora,
encode the same input via Python (in-process ctypes), Java
(MateInfoV2Cli subprocess), and ObjC (TtioMateInfoV2Cli subprocess).
All three outputs must be byte-identical inline_v2 blobs.

Each language wraps the same deterministic ttio_mate_info_v2_encode C
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

from ttio.codecs import mate_info_v2 as miv2

REPO = Path("/home/toddw/TTI-O")
NATIVE_LIB_DIR = REPO / "native" / "_build"
JAVA_JAR = REPO / "java" / "target" / "ttio-1.2.0.jar"
OBJC_CLI = REPO / "objc" / "Tools" / "obj" / "TtioMateInfoV2Cli"

CORPORA = [
    ("chr22",          REPO / "data/genomic/na12878/na12878.chr22.lean.mapped.bam"),
    ("wes",            REPO / "data/genomic/na12878_wes/na12878_wes.chr22.bam"),
    ("hg002_illumina", REPO / "data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam"),
    ("hg002_pacbio",   REPO / "data/genomic/hg002_pacbio/hg002_pacbio.subset.bam"),
]

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not miv2.HAVE_NATIVE_LIB, reason="needs libttio_rans"),
    pytest.mark.skipif(not JAVA_JAR.exists(),
                       reason=f"Java jar not built at {JAVA_JAR}"),
    pytest.mark.skipif(not OBJC_CLI.exists(),
                       reason=f"ObjC TtioMateInfoV2Cli not built at {OBJC_CLI}"),
]


from ._mate_info_corpus import extract_mate_triples


def _write_bin_inputs(tmp_path: Path, name: str, mc, mp, ts, oc, op):
    """Write the 5 typed-array .bin files that Java + ObjC CLIs read."""
    files = {
        "mc": tmp_path / f"{name}_mc.bin",
        "mp": tmp_path / f"{name}_mp.bin",
        "ts": tmp_path / f"{name}_ts.bin",
        "oc": tmp_path / f"{name}_oc.bin",
        "op": tmp_path / f"{name}_op.bin",
    }
    np.ascontiguousarray(mc, dtype="<i4").tofile(str(files["mc"]))
    np.ascontiguousarray(mp, dtype="<i8").tofile(str(files["mp"]))
    np.ascontiguousarray(ts, dtype="<i4").tofile(str(files["ts"]))
    np.ascontiguousarray(oc, dtype="<u2").tofile(str(files["oc"]))
    np.ascontiguousarray(op, dtype="<i8").tofile(str(files["op"]))
    return files


@pytest.mark.parametrize("name,bam_path", CORPORA, ids=[c[0] for c in CORPORA])
def test_mate_info_v2_cross_language_byte_equal(tmp_path, name, bam_path):
    if not bam_path.exists():
        pytest.skip(f"corpus not present: {bam_path}")

    # Step 1: Extract mate triples via the canonical Python helper.
    mc, mp, ts, oc, op = extract_mate_triples(bam_path)
    n = mc.shape[0]
    assert n > 0, f"empty corpus {name}"

    # Step 2: Encode via Python in-process.
    py_blob = miv2.encode(mc, mp, ts, oc, op)

    # Step 3: Write the typed-array .bin files for Java + ObjC.
    files = _write_bin_inputs(tmp_path, name, mc, mp, ts, oc, op)

    # Step 4: Encode via Java subprocess (direct java, NOT mvn exec).
    java_out = tmp_path / f"{name}_java.bin"
    java_proc = subprocess.run(
        ["java",
         f"-Djava.library.path={NATIVE_LIB_DIR}",
         "-cp", str(JAVA_JAR),
         "global.thalion.ttio.tools.MateInfoV2Cli",
         str(files["mc"]), str(files["mp"]), str(files["ts"]),
         str(files["oc"]), str(files["op"]), str(java_out)],
        capture_output=True, text=True,
    )
    assert java_proc.returncode == 0, (
        "{}: Java MateInfoV2Cli failed (rc={})\nstderr: {}".format(
            name, java_proc.returncode, java_proc.stderr))
    java_blob = java_out.read_bytes()

    # Step 5: Encode via ObjC subprocess.
    objc_out = tmp_path / f"{name}_objc.bin"
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = (
        "{}:{}/objc/Source/obj:{}".format(
            NATIVE_LIB_DIR, REPO, env.get("LD_LIBRARY_PATH", ""))
    )
    objc_proc = subprocess.run(
        [str(OBJC_CLI),
         str(files["mc"]), str(files["mp"]), str(files["ts"]),
         str(files["oc"]), str(files["op"]), str(objc_out)],
        capture_output=True, text=True, env=env,
    )
    assert objc_proc.returncode == 0, (
        "{}: ObjC TtioMateInfoV2Cli failed (rc={})\nstderr: {}".format(
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
