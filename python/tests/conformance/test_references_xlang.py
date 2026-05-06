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

All three writer helpers use the same direct-graft pattern that the
existing per-language reference tests use (Python's ``_seed_references``
in ``test_references_accessor.py``, Java's
``conformance.RefXLangWriter``, ObjC's ``TtioRefXLangWriter``). This
sidesteps the asymmetric writer-side embed gates (Python: codec
override OR libttio_rans; ObjC: libttio_rans unconditional; Java:
production path requires native FQZCOMP for non-empty quality streams)
while still exercising the same on-disk shape that fires when the
production gates are satisfied.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio import SpectralDataset
from ttio.spectral_dataset import _embed_references_for_runs
from ttio.providers.hdf5 import _Group as _H5Group
from ttio.written_genomic_run import WrittenGenomicRun

# ─── Paths to other-language artefacts ───────────────────────────────

_REPO = Path(__file__).resolve().parents[3]
_JAVA = _REPO / "java"
_OBJC = _REPO / "objc"

_JAVA_TARGET = _JAVA / "target"
_JAVA_CLASSES = _JAVA_TARGET / "classes"
_JAVA_TEST_CLASSES = _JAVA_TARGET / "test-classes"
_JAVA_CLASSPATH_TXT = _JAVA_TARGET / "classpath.txt"
_JAVA_HDF5_JAR = Path("/usr/share/java/jarhdf5.jar")

_OBJC_BIN = _OBJC / "Tools" / "obj"
_OBJC_LIB = _OBJC / "Source" / "obj"

# ─── Canonical reference map (the invariant under test) ─────────────

URI = "xlang-test-v1"
KNOWN_REFS = {
    "chr1": b"ACGTACGTACGT",
    "chr2": b"TTTTAAAACCCC",
}


def _expected_md5_hex() -> str:
    """The on-disk @md5 attribute the production writer stamps.

    All three production writers (Python ``_reference_md5_for_run``,
    Java ``referenceMd5ForRun``, ObjC ``_TTIO_M93_ReferenceMD5ForRun``)
    use the sequence-concat-only form sorted by chromosome name. This
    is NOT the same as the public-API canonical-MD5 helper
    (``compute_reference_md5`` /
    ``ReferenceImport.computeMd5`` /
    ``+[TTIOReferenceImport computeMd5WithChromosomes:sequences:]``)
    which uses the ``name + 0x0A + seq + 0x0A`` form.
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
    """Direct-graft via ``_embed_references_for_runs`` — the same helper
    the production writer uses when its gate fires."""
    from ttio.enums import Compression

    SpectralDataset.write_minimal(
        out, title="xlang", isa_investigation_id="XLANG001", runs={},
    )

    run = WrittenGenomicRun(
        acquisition_mode=7,  # AcquisitionMode.GENOMIC_WGS
        reference_uri=URI,
        platform="ILLUMINA",
        sample_name="REF_TEST",
        positions=np.zeros(0, dtype=np.int64),
        mapping_qualities=np.zeros(0, dtype=np.uint8),
        flags=np.zeros(0, dtype=np.uint32),
        sequences=np.zeros(0, dtype=np.uint8),
        qualities=np.zeros(0, dtype=np.uint8),
        offsets=np.zeros(0, dtype=np.uint64),
        lengths=np.zeros(0, dtype=np.uint32),
        cigars=[],
        read_names=[],
        mate_chromosomes=[],
        mate_positions=np.zeros(0, dtype=np.int64),
        template_lengths=np.zeros(0, dtype=np.int32),
        chromosomes=[],
        signal_codec_overrides={"sequences": Compression.REF_DIFF_V2},
        reference_chrom_seqs=KNOWN_REFS,
        embed_reference=True,
    )
    with h5py.File(str(out), "r+") as f:
        study = f["study"]
        _embed_references_for_runs(_H5Group(study), {"_seed": run})


def _write_java(out: Path) -> None:
    if not _java_runtime_available():
        pytest.skip("Java conformance helpers not built (run `mvn test-compile` in java/)")
    cmd = ["java", "-cp", _java_classpath(),
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
    cmd = ["java", "-cp", _java_classpath(),
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
