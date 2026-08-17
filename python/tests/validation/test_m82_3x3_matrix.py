"""M82.4 cross-language conformance matrix (Python × ObjC × Java).

Each writer language emits a deterministic genomic-only .tio fixture
to ``build/m82_xlang_<lang>.tio``; each reader language opens the
fixture and emits the same flat JSON summary that the v0.9 cross-
language smoke established for MS-only files. The summary is then
compared cell-by-cell across all 9 (writer, reader) pairs.

Cell expectations:

==========  =========  =========  =========
            py-read    objc-read  java-read
py-write    ✓          ✓          ✓
objc-write  ✓          ✓          ✓
java-write  ✓          ✓          ✓
==========  =========  =========  =========

Skip rules:

* The ObjC ``TtioWriteGenomicFixture`` / ``TtioVerify`` binaries must
  be built (``cd objc && ./build.sh``) and locatable; otherwise the
  rows/columns that need them are skipped.
* The Java tooling needs a built classpath (same convention as
  ``test_cross_language_smoke.py``); otherwise the rows/columns that
  need it are skipped.

The deterministic fixture content matches the M82.4 reference shape
shipped in ``python/tests/fixtures/genomic/m82_100reads.tio``: 100
reads × 150 bases, ACGT cycled, qualities = 30, chromosomes round-
robin over {chr1,chr2,chrX}, positions ``10000 + (i//3)*100``, all
unmapped flags zero.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# Reuse the resolver helpers from the existing smoke module so we do
# not duplicate environment-detection logic.
sys.path.insert(0, str(Path(__file__).parent))
from test_cross_language_smoke import (  # type: ignore[import-not-found]
    _resolve_objc_verify,
    _resolve_java_verify,
    _REPO_ROOT,
)

from ttio import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun


_EXPECTED_SUMMARY = {
    "title": "m82-cross-lang-fixture",
    "isa_investigation_id": "ISA-M82-100",
    "ms_runs": {},
    "genomic_runs": {
        "genomic_0001": {
            "read_count": 100,
            "reference_uri": "GRCh38.p14",
            "platform": "ILLUMINA",
            "sample_name": "NA12878",
        }
    },
    "identification_count": 0,
    "quantification_count": 0,
    "provenance_count": 0,
}


# --------------------------------------------------------------------------- #
# Writer helpers — each returns the path of the produced fixture or skips.
# --------------------------------------------------------------------------- #

def _write_python_fixture(tmp_path: Path) -> Path:
    """Build the deterministic genomic-only fixture from Python."""
    import numpy as np

    n_reads = 100
    read_length = 150
    chroms_pool = ["chr1", "chr2", "chrX"]

    chroms = [chroms_pool[i % 3] for i in range(n_reads)]
    positions = np.array(
        [10_000 + (i // 3) * 100 for i in range(n_reads)], dtype=np.int64
    )
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapqs = np.full(n_reads, 60, dtype=np.uint8)

    bases = b"ACGT"
    seq_concat = bytes(bases[i % 4] for i in range(n_reads * read_length))
    qual_concat = bytes([30] * (n_reads * read_length))

    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=mapqs,
        flags=flags,
        sequences=np.frombuffer(seq_concat, dtype=np.uint8),
        qualities=np.frombuffer(qual_concat, dtype=np.uint8),
        offsets=np.arange(n_reads, dtype=np.uint64) * read_length,
        lengths=np.full(n_reads, read_length, dtype=np.uint32),
        cigars=[f"{read_length}M" for _ in range(n_reads)],
        read_names=[f"read_{i:06d}" for i in range(n_reads)],
        mate_chromosomes=["" for _ in range(n_reads)],
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=chroms,
    )
    out = tmp_path / "py_xlang.tio"
    SpectralDataset.write_minimal(
        out, title="m82-cross-lang-fixture",
        isa_investigation_id="ISA-M82-100",
        runs={}, genomic_runs={"genomic_0001": run},
    )
    return out


def _resolve_objc_writer() -> tuple[Path, dict[str, str]] | None:
    """Locate the ObjC TtioWriteGenomicFixture binary + env."""
    explicit = os.environ.get("TTIO_OBJC_GENOMIC_WRITER")
    if explicit and Path(explicit).is_file():
        binary = Path(explicit)
    else:
        binary = (_REPO_ROOT / "objc" / "Tools" / "obj"
                  / "TtioWriteGenomicFixture")
        if not binary.is_file():
            return None
    libdir = _REPO_ROOT / "objc" / "Source" / "obj"
    if not libdir.is_dir():
        return None
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = (
        f"{libdir}:{env.get('LD_LIBRARY_PATH', '')}".rstrip(":")
    )
    return binary, env


def _write_objc_fixture(tmp_path: Path) -> Path:
    objc = _resolve_objc_writer()
    if objc is None:
        pytest.skip("ObjC TtioWriteGenomicFixture binary not built; "
                    "run `cd objc && ./build.sh` first")
    binary, env = objc
    out = tmp_path / "objc_xlang.tio"
    proc = subprocess.run(
        [str(binary), str(out)],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        pytest.fail(f"TtioWriteGenomicFixture (ObjC) exit {proc.returncode}: "
                    f"{proc.stderr.strip()}")
    return out


def _write_java_fixture(tmp_path: Path) -> Path:
    java = _resolve_java_verify()
    if java is None:
        pytest.skip("Java classpath not available")
    argv_prefix, env = java
    # argv_prefix ends with the TtioVerify class name; replace it with
    # the writer class.
    writer_argv = argv_prefix[:-1] + [
        "global.thalion.ttio.tools.TtioWriteGenomicFixture"
    ]
    out = tmp_path / "java_xlang.tio"
    proc = subprocess.run(
        writer_argv + [str(out)],
        capture_output=True, text=True, env=env, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(f"TtioWriteGenomicFixture (Java) exit {proc.returncode}: "
                    f"{proc.stderr.strip()}")
    return out


# --------------------------------------------------------------------------- #
# Reader helpers — each returns the JSON-summary dict for a fixture.
# --------------------------------------------------------------------------- #

def _read_python_summary(path: Path) -> dict:
    with SpectralDataset.open(path) as ds:
        gruns = {
            n: {
                "read_count": len(g),
                "reference_uri": g.reference_uri or "",
                "platform": g.platform or "",
                "sample_name": g.sample_name or "",
            }
            for n, g in sorted(ds.genomic_runs.items())
        }
        return {
            "title": ds.title,
            "isa_investigation_id": ds.isa_investigation_id,
            "ms_runs": {n: {"spectrum_count": len(r)}
                        for n, r in sorted(ds.ms_runs.items())},
            "genomic_runs": gruns,
            "identification_count": len(ds.identifications()),
            "quantification_count": len(ds.quantifications()),
            "provenance_count": len(ds.provenance()),
        }


def _read_objc_summary(path: Path) -> dict:
    objc = _resolve_objc_verify()
    if objc is None:
        pytest.skip("ObjC TtioVerify binary not built")
    binary, env = objc
    proc = subprocess.run(
        [str(binary), str(path)],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        pytest.fail(f"ObjC TtioVerify exit {proc.returncode}: "
                    f"{proc.stderr.strip()}")
    return json.loads(proc.stdout.strip())


def _read_java_summary(path: Path) -> dict:
    java = _resolve_java_verify()
    if java is None:
        pytest.skip("Java classpath not available")
    argv_prefix, env = java
    proc = subprocess.run(
        argv_prefix + [str(path)],
        capture_output=True, text=True, env=env, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(f"Java TtioVerify exit {proc.returncode}: "
                    f"{proc.stderr.strip()}")
    payload = next(
        ln for ln in reversed(proc.stdout.splitlines())
        if ln.strip().startswith("{")
    )
    return json.loads(payload)


# --------------------------------------------------------------------------- #
# 3×3 matrix.
# --------------------------------------------------------------------------- #

_WRITERS = {
    "python": _write_python_fixture,
    "objc":   _write_objc_fixture,
    "java":   _write_java_fixture,
}
_READERS = {
    "python": _read_python_summary,
    "objc":   _read_objc_summary,
    "java":   _read_java_summary,
}

_MATRIX = [(w, r) for w in _WRITERS for r in _READERS]


@pytest.mark.parametrize("writer,reader", _MATRIX,
                         ids=[f"{w}-write_{r}-read" for w, r in _MATRIX])
def test_m82_3x3_conformance(writer: str, reader: str, tmp_path: Path) -> None:
    """Each (writer, reader) cell produces the same canonical summary."""
    fixture = _WRITERS[writer](tmp_path)
    summary = _READERS[reader](fixture)
    assert summary == _EXPECTED_SUMMARY, (
        f"M82.4 cell {writer}->{reader} diverges:\n"
        f"  Got:      {summary}\n"
        f"  Expected: {_EXPECTED_SUMMARY}"
    )


def test_m82_field_level_python_reads_objc_and_java(tmp_path: Path) -> None:
    """Field-level read-side check on the ObjC- and Java-written
    fixtures — ensures the per-read VL_STRING fields (cigar, read_name,
    chromosome) round-trip identically through Python's reader."""
    objc = _resolve_objc_writer()
    java = _resolve_java_verify()
    if objc is None and java is None:
        pytest.skip("Neither ObjC writer nor Java classpath available")

    targets: list[tuple[str, Path]] = []
    if objc is not None:
        targets.append(("objc", _write_objc_fixture(tmp_path)))
    if java is not None:
        targets.append(("java", _write_java_fixture(tmp_path)))

    for tag, fixture in targets:
        with SpectralDataset.open(fixture) as ds:
            gr = ds.genomic_runs["genomic_0001"]
            assert len(gr) == 100
            r0 = gr[0]
            r99 = gr[99]
            assert r0.read_name == "read_000000", tag
            assert r99.read_name == "read_000099", tag
            assert r0.cigar == "150M", tag
            assert r99.cigar == "150M", tag
            assert r0.chromosome == "chr1", tag
            # i=99 lands on chrX (99 % 3 == 0 → chr1; wait — 99 % 3 = 0)
            # Actually: chromosomes_pool[99 % 3] = chromosomes_pool[0] = chr1
            assert r99.chromosome == "chr1", tag
            assert len(r0.sequence) == 150, tag
            # Bases cycle ACGT starting from offset 0.
            assert r0.sequence[0:4] == "ACGT", tag
