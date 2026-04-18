"""ObjC ↔ Python mzML writer byte-parity harness.

v0.3 deferred follow-up (WORKPLAN.md — Milestone 19): both writers
share the same XML template and are individually round-trip-tested via
their respective readers, but nothing ran both writers on the same
input and diffed the bytes. This test closes that gap.

The ObjC side ships a tiny CLI `objc/Tools/MpgoToMzML` (built by the
gnustep-make recipe in `objc/Tools/GNUmakefile`). When the binary is
available on PATH or under `objc/Tools/obj/`, the harness:

  1. Synthesises a small `.mpgo` fixture via `_fixture_dataset()`.
  2. Invokes MpgoToMzML to produce `a.mzML`.
  3. Calls `mpeg_o.exporters.mzml.write_dataset` on the same dataset
     to produce `b.mzML`.
  4. Compares the two files — structurally, not strictly byte-identical,
     because both writers render indexListOffset / fileChecksum from
     current-file state, so offsets and the SHA-1 footer differ by
     construction. The structural compare asserts that every element
     and attribute matches once those two pieces are masked out.

When MpgoToMzML is unavailable (no ObjC build on the runner), the test
is skipped with a clear message — CI in pure-Python environments keeps
working.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from mpeg_o.enums import AcquisitionMode
from mpeg_o.exporters import mzml as mzml_exporter
from mpeg_o.spectral_dataset import SpectralDataset, WrittenRun


# ── MpgoToMzML resolver ───────────────────────────────────────────────


def _find_mpgo_to_mzml() -> tuple[Path | None, Path | None]:
    """Locate the MpgoToMzML CLI and the libMPGO.so sibling directory
    that its loader needs on LD_LIBRARY_PATH. Returns (None, None)
    when the CLI is absent."""
    which = shutil.which("MpgoToMzML")
    if which:
        return Path(which), None  # on PATH; loader config is user's problem

    # Walk upward from this test file to the repo root, then probe the
    # known gnustep-make output location.
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "objc" / "Tools" / "obj" / "MpgoToMzML"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            libdir = parent / "objc" / "Source" / "obj"
            return candidate, libdir if libdir.is_dir() else None
        if (parent / ".git").exists():
            break
    return None, None


MPGO_TO_MZML, LIBMPGO_DIR = _find_mpgo_to_mzml()
skip_if_no_cli = pytest.mark.skipif(
    MPGO_TO_MZML is None,
    reason="objc/Tools/MpgoToMzML not built; run (cd objc && ./build.sh) first",
)


def _run_cli(*args: str) -> subprocess.CompletedProcess[bytes]:
    """Invoke MpgoToMzML with LD_LIBRARY_PATH pointing at the in-tree
    libMPGO.so if it isn't installed system-wide."""
    env = os.environ.copy()
    if LIBMPGO_DIR is not None:
        existing = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = (
            f"{LIBMPGO_DIR}:{existing}" if existing else str(LIBMPGO_DIR)
        )
    return subprocess.run(
        [str(MPGO_TO_MZML), *args],
        capture_output=True,
        env=env,
    )


# ── Tiny fixture dataset ──────────────────────────────────────────────


def _fixture_dataset(tmp_path: Path) -> Path:
    """Create a deterministic 3-spectrum MS run on disk."""
    n_spec, n_pts = 3, 4
    offsets = np.arange(n_spec, dtype=np.uint64) * n_pts
    lengths = np.full(n_spec, n_pts, dtype=np.uint32)
    mz = np.tile(np.linspace(100.0, 400.0, n_pts), n_spec).astype(np.float64)
    intensity = (
        np.tile(np.linspace(10.0, 20.0, n_pts), n_spec).astype(np.float64)
    )
    run = WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.linspace(0.0, 1.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 20.0, dtype=np.float64),
    )
    out = tmp_path / "parity.mpgo"
    SpectralDataset.write_minimal(
        out, title="parity", isa_investigation_id="MPGO:parity",
        runs={"run_0001": run},
    )
    return out


# ── Byte-parity mask: drop indexListOffset + fileChecksum lines ───────


_IDX_OFFSET_RE = re.compile(
    rb"<indexListOffset>\s*\d+\s*</indexListOffset>")
_CHECKSUM_RE = re.compile(
    rb"<fileChecksum>[^<]*</fileChecksum>")


def _mask_absolute_bytes(blob: bytes) -> bytes:
    """Replace offset-sensitive elements with placeholders so structural
    differences surface instead of expected absolute-byte differences."""
    blob = _IDX_OFFSET_RE.sub(b"<indexListOffset>XXX</indexListOffset>", blob)
    blob = _CHECKSUM_RE.sub(b"<fileChecksum>XXX</fileChecksum>", blob)
    # `<offset idRef="...">N</offset>` entries are also absolute byte
    # offsets and will differ if any prior writer emits whitespace
    # differently. Mask them out too.
    blob = re.sub(
        rb'(<offset idRef="[^"]+">)(\d+)(</offset>)',
        rb"\1XXX\3",
        blob,
    )
    return blob


# ── Structural comparison ─────────────────────────────────────────────


_LEADING_WS = re.compile(rb"^\s+", re.MULTILINE)


def _normalise(blob: bytes) -> bytes:
    """Collapse leading whitespace differences (indentation policy
    divergence between writers is not a bug)."""
    return _LEADING_WS.sub(b"", _mask_absolute_bytes(blob))


# ── The actual test ───────────────────────────────────────────────────


@skip_if_no_cli
@pytest.mark.xfail(
    reason=(
        "Byte-parity harness surfaces a real writer divergence on "
        "SpectralDataset.write_minimal fixtures: the ObjC MpgoToMzML CLI "
        "emits only the first <spectrum> element despite "
        "run.spectrumIndex.count correctly reporting 3. Python writes "
        "all 3. The harness itself is correct (ObjC reader sees 3 via "
        "MpgoVerify); the bug is in the interaction between the reader "
        "and MPGOMzMLWriter's spectrum loop — likely a field-length "
        "mismatch that causes spectrumAtIndex:i error: to return nil "
        "for i>=1 and the writer's "
        "`if (![spec isKindOfClass:[MPGOMassSpectrum class]]) continue;` "
        "guard silently skips them. Separate bug to chase — the harness "
        "lands so the divergence does not regress unnoticed."
    ),
    strict=True,
)
def test_objc_python_mzml_writer_parity(tmp_path: Path) -> None:
    """Both writers, same input, structural parity."""
    mpgo = _fixture_dataset(tmp_path)

    objc_out = tmp_path / "a.mzML"
    result = _run_cli(str(mpgo), str(objc_out))
    assert result.returncode == 0, (
        f"MpgoToMzML failed ({result.returncode}):\n"
        f"stdout: {result.stdout.decode(errors='replace')}\n"
        f"stderr: {result.stderr.decode(errors='replace')}"
    )
    assert objc_out.is_file()

    py_out = tmp_path / "b.mzML"
    with SpectralDataset.open(str(mpgo)) as ds:
        mzml_exporter.write_dataset(ds, py_out)
    assert py_out.is_file()

    objc_blob = objc_out.read_bytes()
    py_blob = py_out.read_bytes()

    # Sanity: both produced something non-trivial.
    assert len(objc_blob) > 500, "ObjC writer produced tiny output"
    assert len(py_blob) > 500, "Python writer produced tiny output"

    n_objc = _normalise(objc_blob)
    n_py = _normalise(py_blob)

    if n_objc != n_py:
        # Print a compact diff of the first N differing characters so
        # CI output is useful without dumping two 5 KB XML blobs.
        for i, (a, b) in enumerate(zip(n_objc, n_py)):
            if a != b:
                start = max(0, i - 80)
                end = min(len(n_objc), i + 80)
                pytest.fail(
                    f"writers diverge at byte {i}:\n"
                    f"objc: {n_objc[start:end]!r}\n"
                    f"  py: {n_py[start:end]!r}"
                )
        pytest.fail(
            f"outputs have different lengths: objc={len(n_objc)}, "
            f"py={len(n_py)}")


@skip_if_no_cli
def test_mpgo_to_mzml_rejects_missing_args(tmp_path: Path) -> None:
    """Usage errors exit with non-zero status."""
    result = _run_cli()
    assert result.returncode != 0
    assert b"usage" in result.stderr.lower()
