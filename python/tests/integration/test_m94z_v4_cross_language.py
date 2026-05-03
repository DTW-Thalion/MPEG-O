"""V4 cross-language byte-equality matrix (Python ↔ Java ↔ ObjC).

Phase 5 cross-language gate: for each of 4 corpora, encode via
Python V4, Java V4, and ObjC V4. All three outputs must be byte-
identical M94Z V4 streams.

Each language wraps the same deterministic ``ttio_m94z_v4_encode`` C
function (Python via ctypes, Java via JNI, ObjC by linking
``libttio_rans``), so the results must agree.

Tagged ``integration``; deselected by default. Run with
``pytest -m integration``.

Pre-reqs:
- ``libttio_rans`` built (``native/_build/libttio_rans.so``).
- ``libttio_rans_jni`` built (``native/_build/libttio_rans_jni.so``).
- Java jar built (``mvn -DskipTests package`` in ``java/``).
- ObjC ``TtioM94zV4Cli`` built (``./build.sh`` in ``objc/``).
- Corpus BAMs present in ``data/genomic/`` (skip-cleanly otherwise).
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio.codecs.fqzcomp_nx16_z import _HAVE_NATIVE_LIB, decode_with_metadata, encode
from ttio.importers.bam import BamReader

REPO = Path("/home/toddw/TTI-O")
NATIVE_LIB_DIR = REPO / "native" / "_build"
JAVA_JAR = REPO / "java" / "target" / "ttio-1.2.0.jar"
OBJC_CLI = REPO / "objc" / "Tools" / "obj" / "TtioM94zV4Cli"
OBJC_LIBS = REPO / "objc" / "Source" / "obj"

CORPORA = [
    ("chr22",          REPO / "data/genomic/na12878/na12878.chr22.lean.mapped.bam"),
    ("wes",            REPO / "data/genomic/na12878_wes/na12878_wes.chr22.bam"),
    ("hg002_illumina", REPO / "data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam"),
    ("hg002_pacbio",   REPO / "data/genomic/hg002_pacbio/hg002_pacbio.subset.bam"),
]

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not _HAVE_NATIVE_LIB, reason="V4 needs libttio_rans"),
    pytest.mark.skipif(not JAVA_JAR.exists(),
                       reason=f"Java jar not built at {JAVA_JAR}"),
    pytest.mark.skipif(not OBJC_CLI.exists(),
                       reason=f"ObjC TtioM94zV4Cli not built at {OBJC_CLI}"),
]


def _first_diff(a: bytes, b: bytes) -> int:
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return n if len(a) != len(b) else -1


@pytest.mark.parametrize("name,bam_path", CORPORA, ids=[c[0] for c in CORPORA])
def test_v4_cross_language_byte_equal(tmp_path, name, bam_path):
    if not bam_path.exists():
        pytest.skip(f"corpus not present: {bam_path}")

    # Step 1: Extract qualities + lengths + flags via BamReader (the
    # reference extraction path used by all 3 language harnesses).
    run = BamReader(str(bam_path)).to_genomic_run(name="run")
    qualities = bytes(run.qualities.tobytes())
    read_lengths = [int(x) for x in run.lengths]
    revcomp = [int(f) for f in run.flags]

    # Step 2: Write inputs to tmp_path for the Java/ObjC CLI tools.
    qual_bin = tmp_path / f"{name}_qual.bin"
    lens_bin = tmp_path / f"{name}_lens.bin"
    flags_bin = tmp_path / f"{name}_flags.bin"
    qual_bin.write_bytes(qualities)
    np.array(read_lengths, dtype=np.uint32).tofile(str(lens_bin))
    np.array(revcomp, dtype=np.uint32).tofile(str(flags_bin))

    # Step 3: Encode via Python V4.
    py_bytes = encode(qualities, read_lengths, revcomp, prefer_v4=True)

    # Step 4: Encode via Java V4 (subprocess M94zV4Cli on the same
    # binary inputs Java CLI just read from disk).
    java_out = tmp_path / f"{name}_java.fqz"
    proc = subprocess.run(
        ["java",
         f"-Djava.library.path={NATIVE_LIB_DIR}",
         "-cp", str(JAVA_JAR),
         "global.thalion.ttio.tools.M94zV4Cli",
         str(qual_bin), str(lens_bin), str(flags_bin), str(java_out)],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, (
        f"{name}: Java M94zV4Cli failed (rc={proc.returncode})\n"
        f"stderr: {proc.stderr}"
    )
    java_bytes = java_out.read_bytes()

    # Step 5: Encode via ObjC V4 (subprocess TtioM94zV4Cli).
    objc_out = tmp_path / f"{name}_objc.fqz"
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = (
        f"{OBJC_LIBS}:{NATIVE_LIB_DIR}:" + env.get("LD_LIBRARY_PATH", "")
    )
    proc = subprocess.run(
        [str(OBJC_CLI),
         str(qual_bin), str(lens_bin), str(flags_bin), str(objc_out)],
        capture_output=True, text=True, env=env,
    )
    assert proc.returncode == 0, (
        f"{name}: ObjC TtioM94zV4Cli failed (rc={proc.returncode})\n"
        f"stderr: {proc.stderr}"
    )
    objc_bytes = objc_out.read_bytes()

    # Step 6: All 3 must be byte-identical (within-encode parity).
    if py_bytes != java_bytes:
        d = _first_diff(py_bytes, java_bytes)
        pytest.fail(
            f"{name}: Python={len(py_bytes):,}B Java={len(java_bytes):,}B "
            f"first diff at offset {d}"
        )
    if py_bytes != objc_bytes:
        d = _first_diff(py_bytes, objc_bytes)
        pytest.fail(
            f"{name}: Python={len(py_bytes):,}B ObjC={len(objc_bytes):,}B "
            f"first diff at offset {d}"
        )

    # Cross-decode: each language's output must round-trip via the
    # Python decoder back to the original qualities. (Python decoder is
    # the reference; Java/ObjC decoders are exercised in their own
    # unit suites — the byte-equality already proves their encoders
    # produce identical streams to Python's, so the Python decoder
    # is sufficient as a cross-check here.)
    for label, blob in [("python", py_bytes), ("java", java_bytes),
                        ("objc", objc_bytes)]:
        recovered_qualities, recovered_lens, _ = decode_with_metadata(
            blob, revcomp
        )
        assert bytes(recovered_qualities) == qualities, (
            f"{name}/{label}: Python decode failed to recover qualities"
        )
        assert list(recovered_lens) == read_lengths, (
            f"{name}/{label}: Python decode recovered lengths differ"
        )
