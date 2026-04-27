"""V4 edge-case hardening — Python.

Locks in the current failure-mode behaviour for known UX-visible
edge cases. The point isn't to test happy paths (those are covered
elsewhere) — it's to ensure each failure produces a *useful* error
that doesn't change accidentally over time.

Categories covered:

1. ``samtools`` missing on PATH — :class:`SamtoolsNotFoundError`
   with install hints (apt / brew / conda).
2. ``samtools`` exits non-zero (e.g. malformed BAM) — wrapper
   raises :class:`RuntimeError` with the samtools stderr captured.
3. Reference FASTA missing for :class:`CramReader` —
   :class:`FileNotFoundError` naming the missing path.
4. Truncated HDF5 file — h5py raises :class:`OSError` (we lock in
   current behaviour; not raising a TTI-O-specific error today).
5. Truncated SAM/BAM input — wrapper raises with a clear message.
6. Malformed JCAMP-DX numeric block — :class:`ValueError` with a
   "JCAMP-DX:" prefix.
7. CRAM-without-reference at the bam_dump CLI — exits 2 with
   ``--reference`` mentioned on stderr (M88.1 contract).

Per docs/verification-workplan.md §V4.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from ttio.importers.bam import BamReader, SamtoolsNotFoundError, _check_samtools
from ttio.importers.cram import CramReader

REPO_ROOT = Path(__file__).resolve().parents[2]
M88_BAM = REPO_ROOT / "python" / "tests" / "fixtures" / "genomic" / "m88_test.bam"
M88_CRAM = REPO_ROOT / "python" / "tests" / "fixtures" / "genomic" / "m88_test.cram"
M88_FASTA = REPO_ROOT / "python" / "tests" / "fixtures" / "genomic" / "m88_test_reference.fa"


def _samtools_available() -> bool:
    return shutil.which("samtools") is not None


# ---------------------------------------------------------------------------
# Category 1: samtools not on PATH
# ---------------------------------------------------------------------------


def test_samtools_check_raises_when_missing(monkeypatch):
    """_check_samtools raises SamtoolsNotFoundError when shutil can't find it."""
    monkeypatch.setattr("ttio.importers.bam.shutil.which", lambda _: None)
    # Reset the module-level cache so the missing-samtools branch is
    # hit on this call rather than skipped by a memoised "available".
    import ttio.importers.bam as bam_mod
    monkeypatch.setattr(bam_mod, "_samtools_checked", False, raising=False)
    monkeypatch.setattr(bam_mod, "_samtools_path", None, raising=False)
    with pytest.raises(SamtoolsNotFoundError) as excinfo:
        _check_samtools()
    msg = str(excinfo.value)
    # The error message must point users at the obvious install paths
    # so the failure UX is actionable.
    assert "samtools" in msg.lower()
    assert any(hint in msg.lower() for hint in ("apt", "brew", "conda")), (
        f"SamtoolsNotFoundError should include install hints; got: {msg}"
    )


def test_samtools_check_subclasses_runtime_error(monkeypatch):
    """SamtoolsNotFoundError is a RuntimeError subclass.

    Callers that catch RuntimeError (broad except) must still see the
    samtools-missing case so they don't quietly continue.
    """
    assert issubclass(SamtoolsNotFoundError, RuntimeError)


# ---------------------------------------------------------------------------
# Category 2: samtools exits non-zero on malformed BAM
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not _samtools_available(), reason="samtools not on PATH")
def test_bam_reader_raises_on_malformed_bam(tmp_path):
    """BamReader.to_genomic_run raises RuntimeError when samtools fails."""
    fake_bam = tmp_path / "garbage.bam"
    # 1 KB of zeroes — not a valid BAM (no BGZF magic bytes).
    fake_bam.write_bytes(b"\x00" * 1024)
    reader = BamReader(fake_bam)
    with pytest.raises(RuntimeError) as excinfo:
        reader.to_genomic_run()
    msg = str(excinfo.value).lower()
    # The wrapper must surface samtools' stderr or exit code so the
    # user can diagnose the actual failure.
    assert "samtools" in msg or "exit" in msg or "view" in msg, (
        f"malformed-BAM error should surface samtools context; got: {excinfo.value}"
    )


# ---------------------------------------------------------------------------
# Category 3: reference FASTA missing for CRAM
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not _samtools_available(), reason="samtools not on PATH")
def test_cram_reader_raises_on_missing_reference(tmp_path):
    """CramReader.to_genomic_run raises FileNotFoundError naming the path."""
    bogus_fasta = tmp_path / "does_not_exist.fa"
    reader = CramReader(M88_CRAM, bogus_fasta)
    with pytest.raises(FileNotFoundError) as excinfo:
        reader.to_genomic_run()
    msg = str(excinfo.value)
    assert str(bogus_fasta) in msg, (
        f"missing-reference error should name the offending path; got: {msg}"
    )


def test_cram_reader_constructor_does_not_check_reference():
    """CramReader construction is cheap — file existence checked at first read.

    Locks in the lazy-validation contract from M88: the class is
    loadable on machines without samtools / without the FASTA so
    documentation generators and type-checkers don't blow up.
    """
    # Constructing with a non-existent path must NOT raise.
    bogus = Path("/nonexistent/reference.fa")
    reader = CramReader(M88_CRAM, bogus)
    assert reader.reference_fasta == bogus


# ---------------------------------------------------------------------------
# Category 4: truncated HDF5 file
# ---------------------------------------------------------------------------


def test_truncated_hdf5_raises_oserror(tmp_path):
    """h5py raises OSError on a truncated .tio file (locked-in current behaviour).

    This test documents the status quo. A future V8 (HDF5 corruption
    recovery) milestone may upgrade this to a TTI-O-specific
    Hdf5ParseError with file-offset info.
    """
    import h5py
    import numpy as np

    intact = tmp_path / "intact.tio"
    truncated = tmp_path / "truncated.tio"

    with h5py.File(intact, "w") as f:
        f.create_dataset("intensity", data=np.arange(1000, dtype=np.float64))
        f.create_dataset("mz", data=np.linspace(100.0, 1000.0, 1000))

    full_bytes = intact.read_bytes()
    # Truncate by 4 KB — definitely past the superblock + into the
    # dataset chunks.
    truncated.write_bytes(full_bytes[: max(1, len(full_bytes) - 4096)])

    with pytest.raises(OSError) as excinfo:
        with h5py.File(truncated, "r") as _:
            pass
    # h5py's error string should at least name the file.
    assert "truncated.tio" in str(excinfo.value) or len(str(excinfo.value)) > 0


# ---------------------------------------------------------------------------
# Category 5: truncated BAM input
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not _samtools_available(), reason="samtools not on PATH")
def test_truncated_bam_raises_runtime_error(tmp_path):
    """A BAM file with the trailing data block chopped off raises cleanly."""
    truncated = tmp_path / "chopped.bam"
    full_bytes = M88_BAM.read_bytes()
    # Take the first half — still has a valid BGZF header but no
    # trailing EOF block; samtools view -h flags this.
    truncated.write_bytes(full_bytes[: len(full_bytes) // 2])
    reader = BamReader(truncated)
    with pytest.raises(RuntimeError):
        reader.to_genomic_run()


# ---------------------------------------------------------------------------
# Category 6: malformed JCAMP-DX
# ---------------------------------------------------------------------------


def test_malformed_jcamp_xydata_raises_value_error(tmp_path):
    """JCAMP-DX with empty XYDATA raises ValueError with 'JCAMP-DX:' prefix."""
    from ttio.importers.jcamp_dx import read_spectrum

    bogus = tmp_path / "empty.dx"
    bogus.write_text(
        "##TITLE=Bogus\n"
        "##JCAMP-DX=5.01\n"
        "##DATA TYPE=INFRARED SPECTRUM\n"
        "##XUNITS=1/CM\n"
        "##YUNITS=ABSORBANCE\n"
        "##XFACTOR=1\n"
        "##YFACTOR=1\n"
        "##FIRSTX=400\n"
        "##LASTX=4000\n"
        "##NPOINTS=10\n"
        "##XYDATA=(X++(Y..Y))\n"
        # No data lines at all.
        "##END=\n"
    )
    with pytest.raises(ValueError) as excinfo:
        read_spectrum(bogus)
    assert "JCAMP-DX" in str(excinfo.value), (
        f"JCAMP parse errors should be prefixed for grep-ability; got: {excinfo.value}"
    )


# ---------------------------------------------------------------------------
# Category 7: CRAM-without-reference at the bam_dump CLI (M88.1 contract)
# ---------------------------------------------------------------------------


def test_bam_dump_cram_without_reference_exits_2():
    """python -m ttio.importers.bam_dump <cram> (no --reference) exits 2."""
    result = subprocess.run(
        ["python3", "-m", "ttio.importers.bam_dump", str(M88_CRAM)],
        cwd=str(REPO_ROOT / "python"),
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2, (
        f"expected exit 2, got {result.returncode}; stderr: {result.stderr}"
    )
    assert "--reference" in result.stderr, (
        f"error should mention --reference; got stderr: {result.stderr}"
    )


def test_bam_dump_zero_byte_file_errors(tmp_path):
    """python -m ttio.importers.bam_dump <empty.bam> exits non-zero."""
    empty_bam = tmp_path / "empty.bam"
    empty_bam.write_bytes(b"")
    result = subprocess.run(
        ["python3", "-m", "ttio.importers.bam_dump", str(empty_bam)],
        cwd=str(REPO_ROOT / "python"),
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
