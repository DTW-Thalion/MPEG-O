#!/usr/bin/env python3
"""R8 Cython linetrace coverage runner.

Measures line coverage of the runtime-exercised Cython codec extensions
(_rans, _delta_rans) and optionally enforces a floor. Encapsulates the
workarounds needed for coverage.py 7.x + Cython.Coverage + numpy 2.x:

  * COVERAGE_CORE=ctrace  — the C tracer; coverage.py's default sys.monitoring
    core does not support the Cython plugin.
  * CYTHON_TRACE=1        — activates the linetrace hooks compiled in via the
    TTIO_CYTHON_LINETRACE build option (CYTHON_TRACE_NOGIL=1).
  * The cython-generated _<mod>.c (built with linetrace) is copied next to each
    .pyx so Cython.Coverage can map executed lines back to source.
  * numpy and the extensions are imported BEFORE coverage starts: numpy 2.x
    raises "cannot load module more than once per process" if the C tracer is
    active during its first import.
  * pytest-cov is disabled (-p no:cov) so it does not install a second tracer.

Prerequisite — build the package with linetrace first:
    pip install -e . --no-build-isolation \\
        --config-settings=cmake.define.TTIO_CYTHON_LINETRACE=ON

Usage:  python scripts/run_cython_coverage.py [--fail-under N]
Exit 0 if coverage >= floor (and tests pass); nonzero otherwise.

Only the two runtime-exercised codec extensions (_rans, _delta_rans) have
Cython accelerators. The fqzcomp codec is native-only (libttio_rans); its
native C is covered by the native C half (scripts/native-coverage.sh).
"""
from __future__ import annotations

import argparse
import glob
import os
import shutil
import sys
from pathlib import Path

# Must be set before coverage / the extensions are imported.
os.environ["CYTHON_TRACE"] = "1"
os.environ["COVERAGE_CORE"] = "ctrace"  # required; the default sysmon core doesn't support the Cython plugin

HERE = Path(__file__).resolve().parent.parent  # the python/ dir
os.chdir(HERE)
CODECS = HERE / "src" / "ttio" / "codecs"
MODS = ["_rans", "_delta_rans"]  # runtime-exercised Cython extensions

CURATED_TESTS = [
    "tests/test_rans_unit.py",
    "tests/test_m83_rans.py",
    "tests/test_delta_rans_fallback.py",
    "tests/test_delta_rans_vectorization.py",
    "tests/test_m95_delta_rans.py",
    "tests/test_codec_registry.py",
]
# linetrace tracing slows the 10MB throughput test below its assert floor
# (a profiler artifact, not a regression) — deselect it.
DESELECT = ["--deselect", "tests/test_m83_rans.py::test_14_throughput_order0_10mb"]


def _stage_generated_c() -> None:
    """Copy each linetrace-built _<mod>.c next to its .pyx for line mapping."""
    for mod in MODS:
        # Single-level glob: scikit-build-core emits the generated .c at
        # build/<abi-tag>/_<mod>.c (one level deep).
        matches = sorted(glob.glob(str(HERE / "build" / "*" / f"{mod}.c")))
        if not matches:
            sys.exit(
                f"ERROR: linetrace-generated {mod}.c not found under "
                f"{HERE / 'build'}/*/. Build with "
                f"-DTTIO_CYTHON_LINETRACE=ON first."
            )
        src = matches[-1]
        with open(src, "r", errors="replace") as fh:
            generated = fh.read()
        if "__Pyx_TraceLine" not in generated:
            sys.exit(
                f"ERROR: {src} was generated WITHOUT linetrace. Rebuild with "
                f"-DTTIO_CYTHON_LINETRACE=ON before measuring coverage."
            )
        shutil.copyfile(src, CODECS / mod / f"{mod}.c")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fail-under", type=float, default=None,
                    help="Fail if total line coverage is below this percent.")
    args = ap.parse_args()

    _stage_generated_c()

    import numpy  # noqa: F401  (pre-import before the C tracer starts)
    import ttio.codecs._rans._rans  # noqa: F401
    import ttio.codecs._delta_rans._delta_rans  # noqa: F401

    import coverage
    import pytest
    from coverage.exceptions import NoDataError

    cov = coverage.Coverage(config_file=str(HERE / "coverage-cython.cfg"))
    cov.start()
    rc = pytest.main(["-q", "-p", "no:cov", "-p", "no:cacheprovider",
                      *DESELECT, *CURATED_TESTS])
    cov.stop()
    cov.save()
    if rc == pytest.ExitCode.NO_TESTS_COLLECTED:
        sys.exit("ERROR: no tests collected — check the CURATED_TESTS paths/names")
    if rc != 0:
        sys.exit(f"pytest failed (rc={rc})")

    try:
        total = cov.report(show_missing=True)
    except NoDataError:
        sys.exit(
            "ERROR: no coverage data mapped — the Cython linetrace build "
            "produced no traced lines. Rebuild with "
            "-DTTIO_CYTHON_LINETRACE=ON and ensure CYTHON_TRACE=1."
        )
    print(f"\nCython codec line coverage: {total:.1f}%")
    if total <= 0.0:
        sys.exit("ERROR: measured 0% — linetrace build is broken.")
    if args.fail_under is not None and total < args.fail_under:
        sys.exit(f"FAIL: coverage {total:.1f}% < floor {args.fail_under}%")


if __name__ == "__main__":
    main()
