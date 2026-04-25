"""v0.7 M51 — cross-language compound writes byte-parity harness.

Exercises the three compound-dataset dumpers — Python, Java, and
Objective-C — against a shared `.tio` fixture. All three must emit
byte-identical canonical JSON.

This is the catch-net for the kind of write-path / read-path drift the
uint64 probe bug (commit `303e324`) represented. The HANDOFF.md M51
spec calls for a 9-way grid (3 writers × 3 dumpers); this initial
harness ships the 3-way grid (1 writer × 3 dumpers) — the read-side
direction that produced the 303e324 bug. The writer-direction
expansion (Java + ObjC write-fixture CLIs) is deferred.

The harness skips gracefully when the ObjC or Java tooling is not
built locally, so pure-Python CI stays green.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio.enums import AcquisitionMode
from ttio.identification import Identification
from ttio.provenance import ProvenanceRecord
from ttio.quantification import Quantification
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.tools.dump_identifications import dump as python_dump


# ── CLI resolvers ─────────────────────────────────────────────────────


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / ".git").exists():
            return parent
        if (parent / "python" / "pyproject.toml").exists():
            return parent
    return here.parents[2]


def _find_objc_cli() -> tuple[Path | None, Path | None]:
    """Return (cli path, LD_LIBRARY_PATH dir)."""
    which = shutil.which("TtioDumpIdentifications")
    if which:
        return Path(which), None
    root = _repo_root()
    candidate = root / "objc" / "Tools" / "obj" / "TtioDumpIdentifications"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        libdir = root / "objc" / "Source" / "obj"
        return candidate, libdir if libdir.is_dir() else None
    return None, None


def _find_java_runner() -> Path | None:
    """Return path to `run-tool.sh` if the Java project is built, else None."""
    root = _repo_root()
    runner = root / "java" / "run-tool.sh"
    if not runner.is_file() or not os.access(runner, os.X_OK):
        return None
    # Ensure it can actually run: need the target/classes dir.
    if not (root / "java" / "target" / "classes").is_dir():
        return None
    return runner


OBJC_CLI, OBJC_LIB = _find_objc_cli()
JAVA_RUNNER = _find_java_runner()

skip_if_no_objc = pytest.mark.skipif(
    OBJC_CLI is None,
    reason="objc/Tools/TtioDumpIdentifications not built",
)
skip_if_no_java = pytest.mark.skipif(
    JAVA_RUNNER is None,
    reason="java/run-tool.sh / target/classes missing — run `mvn compile` first",
)


# ── Fixture synthesis ─────────────────────────────────────────────────


def _write_fixture(path: Path) -> None:
    """Write a deterministic `.tio` file with 5 identifications, 3
    quantifications, and 7 provenance records."""
    n_spec, n_pts = 3, 4
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={
            "mz": np.tile(np.linspace(100.0, 400.0, n_pts), n_spec),
            "intensity": np.tile(np.linspace(10.0, 20.0, n_pts), n_spec),
        },
        offsets=np.arange(n_spec, dtype=np.uint64) * n_pts,
        lengths=np.full(n_spec, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 1.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 20.0, dtype=np.float64),
    )
    idents = [
        Identification(f"r_{i}", i, f"CHEBI:{100 + i}",
                       round(0.1 + 0.15 * i, 4),
                       [f"ev_{i}_a", f"ev_{i}_b"] if i % 2 == 0 else [])
        for i in range(5)
    ]
    quants = [
        Quantification(f"CHEBI:{200 + i}", f"sample_{i}",
                       1.0 + 0.5 * i, "none" if i == 0 else "")
        for i in range(3)
    ]
    provs = [
        ProvenanceRecord(
            timestamp_unix=1_700_000_000 + i,
            software=f"Tool-{i}-v1.{i}",
            parameters={"mode": f"m{i}", "thr": f"{0.01 * i:g}"},
            input_refs=[f"in_{i}_{j}" for j in range(i % 2)],
            output_refs=[f"out_{i}"],
        )
        for i in range(7)
    ]
    SpectralDataset.write_minimal(
        path, title="M51-parity", isa_investigation_id="TTIO:parity",
        runs={"r_0": run},
        identifications=idents,
        quantifications=quants,
        provenance=provs,
    )


# ── CLI runners ───────────────────────────────────────────────────────


def _run_objc(path: Path) -> bytes:
    env = os.environ.copy()
    if OBJC_LIB is not None:
        existing = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = (
            f"{OBJC_LIB}:{existing}" if existing else str(OBJC_LIB)
        )
    r = subprocess.run(
        [str(OBJC_CLI), str(path)],
        capture_output=True, env=env, check=False,
    )
    assert r.returncode == 0, (
        f"TtioDumpIdentifications failed ({r.returncode}):\n"
        f"stderr: {r.stderr.decode(errors='replace')}"
    )
    return r.stdout


def _run_java(path: Path) -> bytes:
    r = subprocess.run(
        [str(JAVA_RUNNER),
         "com.dtwthalion.ttio.tools.DumpIdentifications",
         str(path)],
        capture_output=True, check=False,
    )
    assert r.returncode == 0, (
        f"java DumpIdentifications failed ({r.returncode}):\n"
        f"stderr: {r.stderr.decode(errors='replace')}"
    )
    return r.stdout


# ── Parity assertions ─────────────────────────────────────────────────


def _first_diff(a: bytes, b: bytes) -> str:
    for i, (ca, cb) in enumerate(zip(a, b)):
        if ca != cb:
            start = max(0, i - 80)
            end = min(len(a), i + 80)
            return (
                f"diverge at byte {i}:\n"
                f"  a: {a[start:end]!r}\n"
                f"  b: {b[start:end]!r}"
            )
    return f"different lengths: a={len(a)} b={len(b)}"


def test_python_dumper_non_trivial(tmp_path: Path) -> None:
    """Sanity check — the Python reference dumper emits the three
    sections with the expected shape."""
    p = tmp_path / "parity.tio"
    _write_fixture(p)
    out = python_dump(p)
    assert out.startswith("{\n")
    assert '"identifications":' in out
    assert '"quantifications":' in out
    assert '"provenance":' in out
    assert out.endswith("\n}\n")


@skip_if_no_objc
def test_python_vs_objc_dump(tmp_path: Path) -> None:
    p = tmp_path / "parity.tio"
    _write_fixture(p)
    py = python_dump(p).encode("utf-8")
    objc = _run_objc(p)
    if py != objc:
        pytest.fail(_first_diff(py, objc))


@skip_if_no_java
def test_python_vs_java_dump(tmp_path: Path) -> None:
    p = tmp_path / "parity.tio"
    _write_fixture(p)
    py = python_dump(p).encode("utf-8")
    java = _run_java(p)
    if py != java:
        pytest.fail(_first_diff(py, java))


@skip_if_no_objc
@skip_if_no_java
def test_java_vs_objc_dump(tmp_path: Path) -> None:
    p = tmp_path / "parity.tio"
    _write_fixture(p)
    objc = _run_objc(p)
    java = _run_java(p)
    if java != objc:
        pytest.fail(_first_diff(java, objc))
