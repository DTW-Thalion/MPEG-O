"""Qualities V5 cross-language file-level edge.

Python writes a genomic ``.tio`` whose motif-correlated qualities
channel comes out as an M94.Z V5 stream; the Java and ObjC reader
helpers open the file through their full file-level paths (the #285
lesson: codec-level unit tests cannot see file-level dispatch bugs)
and print the decoded qualities of the first 3 reads, which must
match the source bytes exactly.

Helpers: ``java .. global.thalion.ttio.conformance.QualXLangReader``
and ``objc/Tools/obj/TtioQualXLangReader``. Cells with a missing
runtime skip, mirroring ``test_references_xlang.py``.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset

_REPO = Path(__file__).resolve().parents[3]
_JAVA = _REPO / "java"
_OBJC = _REPO / "objc"

_JAVA_TARGET = _JAVA / "target"
_JAVA_CLASSES = _JAVA_TARGET / "classes"
_JAVA_TEST_CLASSES = _JAVA_TARGET / "test-classes"
_JAVA_CLASSPATH_TXT = _JAVA_TARGET / "classpath.txt"
_JAVA_HDF5_JAR = Path("/usr/local/lib/jarhdf5.jar")

_OBJC_BIN = _OBJC / "Tools" / "obj"
_OBJC_LIB = _OBJC / "Source" / "obj"

# java.library.path needs native/_build as well: the codec-12 V5
# decode goes through libttio_rans_jni, which local builds leave in
# the CMake build dir (the reference-only helpers never load it).
_JAVA_FLAGS = [
    "--enable-preview",
    "--enable-native-access=ALL-UNNAMED",
    f"-Djava.library.path=/usr/local/lib:{_REPO / 'native' / '_build'}",
]


def _java_runtime_available() -> bool:
    if not _JAVA_CLASSES.is_dir() or not _JAVA_TEST_CLASSES.is_dir():
        return False
    if not _JAVA_CLASSPATH_TXT.is_file() or not _JAVA_HDF5_JAR.is_file():
        return False
    if shutil.which("java") is None:
        return False
    cls = (_JAVA_TEST_CLASSES
           / "global/thalion/ttio/conformance/QualXLangReader.class")
    return cls.is_file()


def _objc_runtime_available() -> bool:
    return ((_OBJC_BIN / "TtioQualXLangReader").is_file()
            and _OBJC_LIB.is_dir())


def _java_classpath() -> str:
    return ":".join((
        str(_JAVA_CLASSES),
        str(_JAVA_TEST_CLASSES),
        _JAVA_CLASSPATH_TXT.read_text().strip(),
        str(_JAVA_HDF5_JAR),
    ))


def _objc_env() -> dict:
    env = os.environ.copy()
    extra = [str(_OBJC_LIB), "/usr/local/lib"]
    cur = env.get("LD_LIBRARY_PATH", "")
    if cur:
        extra.append(cur)
    env["LD_LIBRARY_PATH"] = ":".join(extra)
    return env


def _json_line(stdout: str) -> dict:
    for line in stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            return json.loads(line)
    raise AssertionError(f"no JSON line in reader stdout: {stdout!r}")


N_READS = 11000
READ_LEN = 100


def _write_v5_file(out: Path) -> bytes:
    """Write the motif corpus as a genomic run whose qualities channel
    is a V5 stream; returns the raw quality bytes."""
    from ttio.enums import Compression
    from ttio.written_genomic_run import WrittenGenomicRun

    rng = np.random.default_rng(7)
    bases = np.frombuffer(b"ACGT", dtype=np.uint8)
    bi = rng.integers(0, 4, N_READS * READ_LEN)
    seq = bases[bi]
    qual = (40 + 10 * bi
            + rng.integers(0, 4, bi.shape[0])).astype(np.uint8)

    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="V5_XLANG",
        positions=np.arange(N_READS, dtype=np.int64) * 100 + 10_000,
        mapping_qualities=np.full(N_READS, 60, dtype=np.uint8),
        flags=np.zeros(N_READS, dtype=np.uint32),
        sequences=seq,
        qualities=qual,
        offsets=np.arange(N_READS, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N_READS, READ_LEN, dtype=np.uint32),
        cigars=[f"{READ_LEN}M"] * N_READS,
        read_names=[f"read_{i:06d}" for i in range(N_READS)],
        mate_chromosomes=["*"] * N_READS,
        mate_positions=np.full(N_READS, -1, dtype=np.int64),
        template_lengths=np.zeros(N_READS, dtype=np.int32),
        chromosomes=["chr1"] * N_READS,
        signal_codec_overrides={"qualities": Compression.FQZCOMP_NX16_Z},
    )
    SpectralDataset.write_minimal(
        out, title="v5-xlang", isa_investigation_id="V5X",
        runs={"genomic_0001": run})

    import h5py
    with h5py.File(out, "r") as f:
        blob = bytes(
            f["/study/genomic_runs/genomic_0001/signal_channels/"
              "qualities"][()][:5])
    assert blob[4] == 5, f"expected a V5 stream, got version {blob[4]}"
    return bytes(qual.tobytes())


@pytest.fixture(scope="module")
def v5_file(tmp_path_factory):
    out = tmp_path_factory.mktemp("qualv5") / "v5_xlang.tio"
    qual = _write_v5_file(out)
    return out, qual


def test_python_reads_own_v5(v5_file):
    out, qual = v5_file
    with SpectralDataset.open(out) as ds:
        run = ds.genomic_runs["genomic_0001"]
        got = b"".join(run[i].qualities for i in range(3))
    assert got == qual[:3 * READ_LEN]


def test_java_reads_python_v5(v5_file):
    if not _java_runtime_available():
        pytest.skip("Java conformance helpers not built "
                    "(run `mvn test-compile` in java/)")
    out, qual = v5_file
    cmd = ["java", *_JAVA_FLAGS, "-cp", _java_classpath(),
           "global.thalion.ttio.conformance.QualXLangReader", str(out)]
    r = subprocess.run(cmd, check=True, capture_output=True, text=True,
                       timeout=120)
    got = _json_line(r.stdout)
    assert got["read_count"] == N_READS
    assert got["qualities_hex"] == qual[:3 * READ_LEN].hex()


def test_objc_reads_python_v5(v5_file):
    if not _objc_runtime_available():
        pytest.skip("ObjC conformance helpers not built "
                    "(run `./build.sh` in objc/)")
    out, qual = v5_file
    cmd = [str(_OBJC_BIN / "TtioQualXLangReader"), str(out)]
    r = subprocess.run(cmd, check=True, capture_output=True, text=True,
                       env=_objc_env(), timeout=120)
    got = _json_line(r.stdout)
    assert got["read_count"] == N_READS
    assert got["qualities_hex"] == qual[:3 * READ_LEN].hex()
