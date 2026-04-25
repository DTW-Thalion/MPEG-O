"""Cross-language smoke test (v0.9 M62-x).

Python writes a .tio on every supported provider, then reads back
through both the ObjC ``TtioVerify`` CLI and the Java
``com.dtwthalion.ttio.tools.TtioVerify`` class. Both must produce
the same JSON summary that Python's own reader produces, proving:

* Python's writes are bit-readable from ObjC and Java
* The 4-provider write matrix delivered by M64.5 produces .tio
  files that the canonical (HDF5-only) ObjC + Java readers
  consume — for the providers whose on-disk format IS HDF5
  underneath. Memory / SQLite / Zarr writes are skipped here
  because the ObjC / Java readers are HDF5-only.

The test auto-skips when the ObjC / Java tooling is not available:

* ObjC: requires ``TTIO_OBJC_VERIFY`` env var pointing at the
  built ``TtioVerify`` binary, or the convention path
  ``objc/Tools/obj/TtioVerify`` next to ``libTTIO.so``.
* Java: requires ``TTIO_JAVA_CP`` env var with a Maven-style
  classpath including ``target/classes`` + the test deps, or a
  ``mvn dependency:build-classpath`` invocation that succeeded.

The combination of "Python writes" + "ObjC/Java reads" gives
end-to-end cross-language validation for the on-disk format
guarantee.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from ttio import Identification, SpectralDataset, WrittenRun

_REPO_ROOT = Path(__file__).resolve().parents[3]


def _resolve_objc_verify() -> tuple[Path, dict[str, str]] | None:
    """Locate the built TtioVerify binary + the env vars needed to run it."""
    explicit = os.environ.get("TTIO_OBJC_VERIFY")
    if explicit and Path(explicit).is_file():
        binary = Path(explicit)
    else:
        binary = _REPO_ROOT / "objc" / "Tools" / "obj" / "TtioVerify"
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


def _resolve_java_verify() -> tuple[list[str], dict[str, str]] | None:
    """Build the ``java -cp ... TtioVerify`` argv prefix + env."""
    explicit = os.environ.get("TTIO_JAVA_CP")
    if explicit:
        cp = explicit
    else:
        cp_file = _REPO_ROOT / "java" / "target" / "_smoke_cp.txt"
        if not cp_file.is_file():
            try:
                # Best-effort regenerate; bail if Maven isn't on PATH.
                subprocess.run(
                    ["mvn", "-q", "dependency:build-classpath",
                     "-DincludeScope=test",
                     f"-Dmdep.outputFile={cp_file}"],
                    cwd=_REPO_ROOT / "java",
                    check=True,
                    timeout=120,
                )
            except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return None
        if not cp_file.is_file():
            return None
        cp = cp_file.read_text().strip()
    classes = _REPO_ROOT / "java" / "target" / "classes"
    if not classes.is_dir():
        return None
    if not (classes / "com" / "dtwthalion" / "ttio" / "tools" / "TtioVerify.class").is_file():
        return None
    full_cp = f"{classes}:{cp}"
    env = os.environ.copy()
    # Linux convention path for the JNI HDF5 library; override via
    # TTIO_JAVA_LIB_PATH for non-Debian distros.
    env.setdefault(
        "TTIO_JAVA_LIB_PATH",
        "/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial",
    )
    argv = [
        "java",
        f"-Djava.library.path={env['TTIO_JAVA_LIB_PATH']}",
        "-cp", full_cp,
        "com.dtwthalion.ttio.tools.TtioVerify",
    ]
    return argv, env


@pytest.fixture(scope="module")
def python_ttio(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Write a deterministic HDF5 .tio via Python; both CLIs read it."""
    n = 5
    n_pts = 8
    rng = np.random.default_rng(202604)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n).astype(np.float64)
    intensity = rng.uniform(0.0, 1e6, size=n * n_pts).astype(np.float64)
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum", acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n, dtype=np.uint64) * n_pts,
        lengths=np.full(n, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 4.0, n),
        ms_levels=np.ones(n, dtype=np.int32),
        polarities=np.ones(n, dtype=np.int32),
        precursor_mzs=np.zeros(n),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n, n_pts).max(axis=1),
    )
    ids = [
        Identification("run_0001", 0, "P12345", 0.95, []),
        Identification("run_0001", 2, "P67890", 0.81, []),
    ]
    out = tmp_path_factory.mktemp("xlang") / "py_written.tio"
    SpectralDataset.write_minimal(
        out, title="Cross-language smoke",
        isa_investigation_id="ISA-XLANG",
        runs={"run_0001": run},
        identifications=ids,
    )
    return out


def _python_summary(path: Path) -> dict:
    with SpectralDataset.open(path) as ds:
        runs = {n: {"spectrum_count": len(r)} for n, r in sorted(ds.ms_runs.items())}
        return {
            "title": ds.title,
            "isa_investigation_id": ds.isa_investigation_id,
            "ms_runs": runs,
            "identification_count": len(ds.identifications()),
            "quantification_count": len(ds.quantifications()),
            "provenance_count": len(ds.provenance()),
        }


def test_python_baseline(python_ttio: Path) -> None:
    """Sanity: Python's own reader gives the expected summary so the
    ObjC / Java CLI comparisons have a known reference."""
    summary = _python_summary(python_ttio)
    assert summary == {
        "title": "Cross-language smoke",
        "isa_investigation_id": "ISA-XLANG",
        "ms_runs": {"run_0001": {"spectrum_count": 5}},
        "identification_count": 2,
        "quantification_count": 0,
        "provenance_count": 0,
    }


def test_objc_ttio_verify_matches_python(python_ttio: Path) -> None:
    """Spawn the ObjC ``TtioVerify`` binary; its JSON must match
    Python's view of the same file. Skipped when the binary or
    libTTIO.so is missing."""
    objc = _resolve_objc_verify()
    if objc is None:
        pytest.skip("ObjC TtioVerify binary or libTTIO.so not built; "
                    "run `cd objc && ./build.sh` first")
    binary, env = objc
    proc = subprocess.run(
        [str(binary), str(python_ttio)],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        pytest.fail(f"TtioVerify exit {proc.returncode}: {proc.stderr.strip()}")
    objc_summary = json.loads(proc.stdout.strip())
    py_summary = _python_summary(python_ttio)
    assert objc_summary == py_summary, (
        f"ObjC and Python disagree on the same .tio file:\n"
        f"  ObjC: {objc_summary}\n"
        f"  Py  : {py_summary}"
    )


def test_java_ttio_verify_matches_python(python_ttio: Path) -> None:
    """Spawn the Java ``TtioVerify`` main class; same contract."""
    java = _resolve_java_verify()
    if java is None:
        pytest.skip("Java TtioVerify classpath / target/classes not available; "
                    "run `cd java && mvn compile dependency:build-classpath "
                    "-DincludeScope=test -Dmdep.outputFile=target/_smoke_cp.txt`")
    argv_prefix, env = java
    proc = subprocess.run(
        argv_prefix + [str(python_ttio)],
        capture_output=True, text=True, env=env, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(f"Java TtioVerify exit {proc.returncode}: {proc.stderr.strip()}")
    # Java's slf4j prints two INFO lines on stdout before the JSON. Take
    # the last non-empty line.
    payload_line = next(
        ln for ln in reversed(proc.stdout.splitlines()) if ln.strip().startswith("{")
    )
    java_summary = json.loads(payload_line)
    py_summary = _python_summary(python_ttio)
    assert java_summary == py_summary, (
        f"Java and Python disagree on the same .tio file:\n"
        f"  Java: {java_summary}\n"
        f"  Py  : {py_summary}"
    )


# --------------------------------------------------------------------------- #
# 4-provider cross-language matrix (Java only — ObjC is HDF5-only).
# v0.9 M64.5-objc-java: Java's SpectralDataset.open dispatches on URL
# scheme and reads Memory/SQLite/Zarr natively. ObjC's high-level
# entry points reject non-HDF5 URLs with a clear error (scope limit),
# so the matrix skips ObjC for non-HDF5 cases.
# --------------------------------------------------------------------------- #

_JAVA_TEST_PROVIDERS = ("hdf5", "memory", "sqlite", "zarr")

# Non-HDF5 cross-language interop has one inherent limit:
#   - memory: in-process only by design (separate JVM can't see the
#     Python _STORES dict)
# v0.9 fixes (commit "fix(crosslang)..."): SQLite now passes after
# mapping Python's uint64 offsets to INT64 in _precision_from_dtype;
# Java Zarr now reads compressed chunks (blosc/zlib) via the
# JBlosc + Inflater path.
_CROSSLANG_XFAIL_REASONS = {
    "memory": "in-process-only by design; separate Java process can't see Python memory stores",
}


def _python_writes_on_provider(
    provider: str, tmp_path: Path,
) -> tuple[str, dict]:
    """Write the same logical .tio via Python on ``provider`` and
    return the URL + expected summary dict."""
    import sys as _sys
    _sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
    from _provider_matrix import provider_url as _provider_url  # type: ignore[import-not-found]

    n = 5
    n_pts = 8
    rng = np.random.default_rng(1971)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n).astype(np.float64)
    intensity = rng.uniform(0.0, 1e6, size=n * n_pts).astype(np.float64)
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum", acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n, dtype=np.uint64) * n_pts,
        lengths=np.full(n, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 4.0, n),
        ms_levels=np.ones(n, dtype=np.int32),
        polarities=np.ones(n, dtype=np.int32),
        precursor_mzs=np.zeros(n),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n, n_pts).max(axis=1),
    )
    ids = [
        Identification("run_0001", 0, "P12345", 0.95, []),
        Identification("run_0001", 2, "P67890", 0.81, []),
    ]
    url = _provider_url(provider, tmp_path, "xlang_matrix")
    SpectralDataset.write_minimal(
        url, title=f"xlang-{provider}",
        isa_investigation_id="ISA-XLANG-MATRIX",
        runs={"run_0001": run},
        identifications=ids,
        provider=provider,
    )
    return url, {
        "title": f"xlang-{provider}",
        "isa_investigation_id": "ISA-XLANG-MATRIX",
        "ms_runs": {"run_0001": {"spectrum_count": 5}},
        "identification_count": 2,
        "quantification_count": 0,
        "provenance_count": 0,
    }


@pytest.mark.parametrize("provider", _JAVA_TEST_PROVIDERS)
def test_java_reads_python_4_provider_matrix(
    request, provider: str, tmp_path: Path
) -> None:
    """Python writes through 4 providers; Java ``TtioVerify`` reads
    each via URL-scheme dispatch; JSON summary matches.

    Non-HDF5 cross-language cells are expected-failure (xfail) with
    specific documented reasons — see ``_CROSSLANG_XFAIL_REASONS``.
    """
    java = _resolve_java_verify()
    if java is None:
        pytest.skip("Java TtioVerify classpath not available")
    xfail_reason = _CROSSLANG_XFAIL_REASONS.get(provider)
    if xfail_reason is not None:
        request.applymarker(pytest.mark.xfail(strict=False, reason=xfail_reason))
    url, expected = _python_writes_on_provider(provider, tmp_path)

    argv_prefix, env = java
    proc = subprocess.run(
        argv_prefix + [url],
        capture_output=True, text=True, env=env, timeout=60,
    )
    if proc.returncode != 0:
        pytest.fail(f"Java TtioVerify on {provider} URL exit {proc.returncode}: "
                    f"{proc.stderr.strip()}")
    payload_line = next(
        ln for ln in reversed(proc.stdout.splitlines()) if ln.strip().startswith("{")
    )
    java_summary = json.loads(payload_line)
    assert java_summary == expected, (
        f"Java read of Python-written {provider} dataset diverges:\n"
        f"  Java:     {java_summary}\n"
        f"  Expected: {expected}"
    )


def test_objc_rejects_non_hdf5_url_cleanly(tmp_path: Path) -> None:
    """ObjC's high-level SpectralDataset entry points detect non-HDF5
    URL schemes. A non-existent memory store still surfaces a clean
    error (empty registry, nothing to route to)."""
    objc = _resolve_objc_verify()
    if objc is None:
        pytest.skip("ObjC TtioVerify binary not built")
    binary, env = objc
    proc = subprocess.run(
        [str(binary), "memory://does-not-exist"],
        capture_output=True, text=True, env=env, timeout=15,
    )
    assert proc.returncode != 0, "ObjC should reject non-existent memory store"


# --------------------------------------------------------------------------- #
# v0.9 M64.5-objc-java: ObjC reads Python-written SQLite / Zarr via URL dispatch.
# Memory remains in-process-only. HDF5 is already covered above.
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("provider", ["sqlite", "zarr"])
def test_objc_reads_python_non_hdf5(provider: str, tmp_path: Path) -> None:
    """Python writes through a non-HDF5 provider; ObjC's new
    readViaProviderURL path reads the same summary."""
    objc = _resolve_objc_verify()
    if objc is None:
        pytest.skip("ObjC TtioVerify binary not built")
    binary, env = objc
    url, expected = _python_writes_on_provider(provider, tmp_path)
    proc = subprocess.run(
        [str(binary), url],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        pytest.fail(f"ObjC TtioVerify on {provider} URL exit {proc.returncode}: "
                    f"{proc.stderr.strip()}")
    objc_summary = json.loads(proc.stdout.strip())
    assert objc_summary == expected, (
        f"ObjC read of Python-written {provider} diverges:\n"
        f"  ObjC:     {objc_summary}\n"
        f"  Expected: {expected}"
    )
