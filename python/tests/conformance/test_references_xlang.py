"""Cross-language parity for ``SpectralDataset.references()`` — added in 1.1.0.

For each writer language X ∈ {python, java, objc}: produce a ``.tio``
with the canonical embedded-reference fixture. For each reader language
Y: open X's file and assert the read-back map matches the known
canonical reference map.

9 writer × reader pairs total. All must agree byte-exactly on the
hex-encoded chromosome bytes — that's the on-disk-shape parity
invariant ``ReferenceImport.read_from_group`` /
``ReferenceImport.readFromGroup`` / ``-[TTIOReferenceImport
readFromGroup:]`` were designed to guarantee.

Phase 0 Task 0.12 (tio-browser): all three writer helpers now drive
**production writer entry points** (no direct-graft):

* Python — ``SpectralDataset.write_minimal`` then reopen
  ``writable=True`` and call ``ReferenceImport.write_to_dataset``
  (the public API added in Task 0.10).
* Java — ``SpectralDataset.create`` (returns an open writable dataset)
  and call ``ReferenceImport.writeToDataset`` (Task 0.10c parity).
* ObjC — ``+[TTIOSpectralDataset writeMinimalToPath:...:genomicRuns:...]``
  with one empty-read ``TTIOWrittenGenomicRun`` carrying
  ``embedReference=YES`` + ``referenceChromSeqs=...``. Task 0.11
  softened the embed gate so this no longer needs ``libttio_rans``;
  this exercises the canonical writer path
  (``_TTIO_M93_EmbedReferences``) end-to-end.

That makes this the *first* place where all three production writer
paths are end-to-end byte-equal-verified against each other (and
each other's readers). The earlier direct-graft helpers proved the
storage-provider layer agreed; this proves the writer layer does too.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from ttio import SpectralDataset
from ttio.genomic.reference_import import ReferenceImport

# ─── Paths to other-language artefacts ───────────────────────────────

_REPO = Path(__file__).resolve().parents[3]
_JAVA = _REPO / "java"
_OBJC = _REPO / "objc"

_JAVA_TARGET = _JAVA / "target"
_JAVA_CLASSES = _JAVA_TARGET / "classes"
_JAVA_TEST_CLASSES = _JAVA_TARGET / "test-classes"
_JAVA_CLASSPATH_TXT = _JAVA_TARGET / "classpath.txt"
_JAVA_HDF5_JAR = Path("/usr/local/lib/jarhdf5.jar")  # source-built HDF5 1.14

_OBJC_BIN = _OBJC / "Tools" / "obj"
_OBJC_LIB = _OBJC / "Source" / "obj"

# ─── Canonical reference map (the invariant under test) ─────────────

URI = "xlang-test-v1"
KNOWN_REFS = {
    "chr1": b"ACGTACGTACGT",
    "chr2": b"TTTTAAAACCCC",
}


def _expected_md5_hex() -> str:
    """The single canonical on-disk @md5 form (unified in v1.1.0).

    All three production writers (Python ``_reference_md5_for_run``,
    Java ``referenceMd5ForRun``, ObjC ``_TTIO_M93_ReferenceMD5ForRun``)
    AND the public-API helpers (``compute_reference_md5`` /
    ``ReferenceImport.computeMd5`` /
    ``+[TTIOReferenceImport computeMd5WithChromosomes:sequences:]``)
    now agree on the seq-only form: sort chromosome names
    alphabetically, concatenate sequence bytes verbatim, MD5 the
    result.
    """
    import hashlib
    md = hashlib.md5()
    for name in sorted(KNOWN_REFS):
        md.update(KNOWN_REFS[name])
    return md.hexdigest()


EXPECTED_HEX = {
    URI: {
        "_md5": _expected_md5_hex(),
        **{chrom: seq.hex() for chrom, seq in KNOWN_REFS.items()},
    },
}


# ─── Skip helpers ───────────────────────────────────────────────────

def _java_runtime_available() -> bool:
    """True iff the Java helpers can be exec'd from this pytest run."""
    if not _JAVA_CLASSES.is_dir() or not _JAVA_TEST_CLASSES.is_dir():
        return False
    if not _JAVA_CLASSPATH_TXT.is_file():
        return False
    if not _JAVA_HDF5_JAR.is_file():
        return False
    if shutil.which("java") is None:
        return False
    # Confirm the conformance helpers are compiled (a stale checkout
    # without `mvn test-compile` would silently miss them).
    rxr = (_JAVA_TEST_CLASSES
           / "global/thalion/ttio/conformance/RefXLangReader.class")
    rxw = (_JAVA_TEST_CLASSES
           / "global/thalion/ttio/conformance/RefXLangWriter.class")
    return rxr.is_file() and rxw.is_file()


def _objc_runtime_available() -> bool:
    """True iff the ObjC helpers have been built in this worktree."""
    return ((_OBJC_BIN / "TtioRefXLangWriter").is_file()
            and (_OBJC_BIN / "TtioRefXLangReader").is_file()
            and _OBJC_LIB.is_dir())


def _java_classpath() -> str:
    """Build a Java classpath string from the maven-resolved classpath."""
    return ":".join((
        str(_JAVA_CLASSES),
        str(_JAVA_TEST_CLASSES),
        _JAVA_CLASSPATH_TXT.read_text().strip(),
        str(_JAVA_HDF5_JAR),
    ))


# Java 21 preview-API + FFM flags. The library uses FFM for HDF5 1.14
# VL_BYTES handling; classes compiled with --enable-preview cannot be
# loaded without the same flag at runtime.
# `-Djava.library.path=/usr/local/lib` forces loading the source-built
# HDF5 1.14 libhdf5_java.so; without it Java's default search path picks
# up the lingering apt-installed `libhdf5-jni` 1.10 first and the
# version mismatch triggers UnsatisfiedLinkError on H5 native methods.
_JAVA_FLAGS = [
    "--enable-preview",
    "--enable-native-access=ALL-UNNAMED",
    "-Djava.library.path=/usr/local/lib",
]


def _objc_env() -> dict:
    """Env extending LD_LIBRARY_PATH so libTTIO is resolvable."""
    env = os.environ.copy()
    extra = [str(_OBJC_LIB), "/usr/local/lib"]
    cur = env.get("LD_LIBRARY_PATH", "")
    if cur:
        extra.append(cur)
    env["LD_LIBRARY_PATH"] = ":".join(extra)
    return env


# ─── Writers ────────────────────────────────────────────────────────

def _write_python(out: Path) -> None:
    """Production-writer path: ``SpectralDataset.write_minimal`` to
    create a runs-empty .tio, then reopen ``writable=True`` and call
    the public ``ReferenceImport.write_to_dataset`` API (added in
    Task 0.10). This is the same pattern
    ``test_reference_import_write_round_trip.py`` exercises and is
    the canonical Python embed path now that the public writer API
    exists."""
    SpectralDataset.write_minimal(
        out, title="xlang", isa_investigation_id="XLANG001", runs={},
    )
    ri = ReferenceImport(
        uri=URI,
        chromosomes=list(KNOWN_REFS.keys()),
        sequences=list(KNOWN_REFS.values()),
    )
    with SpectralDataset.open(out, writable=True) as ds:
        ri.write_to_dataset(ds)


def _write_java(out: Path) -> None:
    if not _java_runtime_available():
        pytest.skip("Java conformance helpers not built (run `mvn test-compile` in java/)")
    cmd = ["java", *_JAVA_FLAGS, "-cp", _java_classpath(),
           "global.thalion.ttio.conformance.RefXLangWriter", str(out)]
    subprocess.run(cmd, check=True, capture_output=True, timeout=60)


def _write_objc(out: Path) -> None:
    if not _objc_runtime_available():
        pytest.skip("ObjC conformance helpers not built (run `./build.sh` in objc/)")
    cmd = [str(_OBJC_BIN / "TtioRefXLangWriter"), str(out)]
    subprocess.run(cmd, check=True, capture_output=True, env=_objc_env(), timeout=60)


# ─── Readers ────────────────────────────────────────────────────────

def _read_python(tio: Path) -> dict:
    with SpectralDataset.open(str(tio)) as ds:
        refs = ds.references
        out = {}
        for uri in sorted(refs.keys()):
            r = refs[uri]
            entry = {"_md5": r.md5.hex()}
            for chrom in sorted(r.chromosomes):
                entry[chrom] = r.chromosome(chrom).hex()
            out[uri] = entry
        return out


def _read_java(tio: Path) -> dict:
    if not _java_runtime_available():
        pytest.skip("Java conformance helpers not built (run `mvn test-compile` in java/)")
    cmd = ["java", *_JAVA_FLAGS, "-cp", _java_classpath(),
           "global.thalion.ttio.conformance.RefXLangReader", str(tio)]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=60)
    # Reader prints exactly one JSON line on stdout. Filter for the
    # opening brace to avoid SLF4J / HDF5 INFO chatter.
    for line in out.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            return json.loads(line)
    raise AssertionError(f"no JSON line in Java reader stdout: {out.stdout!r}")


def _read_objc(tio: Path) -> dict:
    if not _objc_runtime_available():
        pytest.skip("ObjC conformance helpers not built (run `./build.sh` in objc/)")
    cmd = [str(_OBJC_BIN / "TtioRefXLangReader"), str(tio)]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True,
                         env=_objc_env(), timeout=60)
    for line in out.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            return json.loads(line)
    raise AssertionError(f"no JSON line in ObjC reader stdout: {out.stdout!r}")


_WRITERS = {"python": _write_python, "java": _write_java, "objc": _write_objc}
_READERS = {"python": _read_python, "java": _read_java, "objc": _read_objc}


# ─── Test ───────────────────────────────────────────────────────────

@pytest.mark.parametrize("writer_lang", list(_WRITERS))
@pytest.mark.parametrize("reader_lang", list(_READERS))
def test_xlang_references_roundtrip(writer_lang, reader_lang, tmp_path):
    tio = tmp_path / f"refs_{writer_lang}_to_{reader_lang}.tio"
    _WRITERS[writer_lang](tio)
    got = _READERS[reader_lang](tio)
    assert got == EXPECTED_HEX, (
        f"writer={writer_lang} reader={reader_lang} mismatch:\n"
        f"  expected: {EXPECTED_HEX}\n"
        f"  got:      {got}"
    )
