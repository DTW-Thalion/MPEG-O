"""M88.1 — bam_dump CLI dispatches to CramReader on `.cram` extension.

Two pytest cases for the Python reference implementation of the
M88.1 ``--reference`` extension to ``bam_dump``:

1. ``test_bam_dump_dispatches_to_cram_reader`` — runs the CLI as a
   subprocess against the M88 CRAM fixture with ``--reference``,
   asserts the JSON parses, ``read_count == 5`` and
   ``sample_name == "M88_TEST_SAMPLE"``. Skipped without samtools.
2. ``test_bam_dump_cram_without_reference_errors`` — runs the CLI on
   the M88 CRAM fixture without ``--reference``, asserts non-zero
   exit and stderr mentions ``--reference``. Argparse rejects before
   samtools is invoked, so no samtools skip needed.

Cross-language equivalents: ObjC ``TtioBamDump`` and Java
``BamDump`` follow the same contract; their cross-language byte
equality is asserted in ``test_m88_cross_language.py``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
PY_DIR = REPO_ROOT / "python"
CRAM_FIXTURE = (
    PY_DIR / "tests" / "fixtures" / "genomic" / "m88_test.cram"
)
REFERENCE_FA = (
    PY_DIR / "tests" / "fixtures" / "genomic" / "m88_test_reference.fa"
)


def _samtools_available() -> bool:
    if shutil.which("samtools") is None:
        return False
    try:
        result = subprocess.run(
            ["samtools", "--version"],
            capture_output=True,
            timeout=5,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


@pytest.mark.skipif(
    not _samtools_available(), reason="samtools not on PATH"
)
def test_bam_dump_dispatches_to_cram_reader():
    """CLI on a .cram path with --reference returns canonical JSON."""
    assert CRAM_FIXTURE.exists(), f"missing fixture: {CRAM_FIXTURE}"
    assert REFERENCE_FA.exists(), f"missing fixture: {REFERENCE_FA}"

    result = subprocess.run(
        [
            "python3", "-m", "ttio.importers.bam_dump",
            str(CRAM_FIXTURE),
            "--reference", str(REFERENCE_FA),
        ],
        cwd=str(PY_DIR),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode == 0, (
        f"CLI failed (exit {result.returncode})\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert result.stdout.startswith("{"), (
        f"stdout does not start with '{{': {result.stdout[:120]!r}"
    )
    payload = json.loads(result.stdout)
    assert payload["read_count"] == 5, (
        f"expected read_count=5, got {payload['read_count']}"
    )
    assert payload["sample_name"] == "M88_TEST_SAMPLE", (
        f"expected sample_name='M88_TEST_SAMPLE', "
        f"got {payload['sample_name']!r}"
    )


def test_bam_dump_cram_without_reference_errors():
    """CLI on a .cram path WITHOUT --reference exits non-zero with
    a stderr message mentioning ``--reference``.

    No samtools dependency: the dispatch logic raises
    :class:`ValueError` before any subprocess is spawned, and
    argparse turns it into an exit-2 error message on stderr.
    """
    assert CRAM_FIXTURE.exists(), f"missing fixture: {CRAM_FIXTURE}"

    result = subprocess.run(
        [
            "python3", "-m", "ttio.importers.bam_dump",
            str(CRAM_FIXTURE),
        ],
        cwd=str(PY_DIR),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode != 0, (
        f"expected non-zero exit, got 0; stdout: {result.stdout!r}"
    )
    assert "--reference" in result.stderr, (
        f"stderr missing '--reference' mention: {result.stderr!r}"
    )
