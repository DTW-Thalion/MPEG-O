"""Cross-implementation compatibility tests.

Two directions are covered:

1. **ObjC → Python.** The Python reader opens every reference ``.mpgo``
   fixture under ``objc/Tests/Fixtures/mpgo/`` and checks that the basic
   metadata + spectrum counts + array shapes decode to the expected values
   documented in that directory's ``README.md``.

2. **Python → ObjC.** When a built ``MpgoVerify`` tool is available (the
   Objective-C build produced ``objc/Tools/obj/MpgoVerify``), a minimal
   ``.mpgo`` file is written from Python and then fed to the tool; its
   JSON summary is parsed and compared field by field.

The second direction is conditionally skipped so the suite stays green on
machines that have only the Python toolchain installed. CI wires both
builds together (see :file:`.github/workflows/ci.yml` ``cross-compat``).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from mpeg_o import (
    Identification,
    MassSpectrum,
    ProvenanceRecord,
    Quantification,
    SpectralDataset,
    WrittenRun,
)
from mpeg_o.enums import AcquisitionMode


_REPO_ROOT = Path(__file__).resolve().parents[2]
_OBJC_FIXTURES = _REPO_ROOT / "objc" / "Tests" / "Fixtures" / "mpgo"


def _mpgo_verify_binary() -> Path | None:
    """Return the path to the built MpgoVerify CLI if it exists."""
    candidates = [
        _REPO_ROOT / "objc" / "Tools" / "obj" / "MpgoVerify",
        _REPO_ROOT / "objc" / "Tools" / "obj" / "ix86_64-linux-gnu-gnu-gnu-gnustep-base" / "MpgoVerify",
    ]
    for c in candidates:
        if c.is_file() and os.access(c, os.X_OK):
            return c
    which = shutil.which("MpgoVerify")
    return Path(which) if which else None


def _libmpgo_dir() -> Path | None:
    """Return the directory containing ``libMPGO.so`` in the build tree."""
    obj = _REPO_ROOT / "objc" / "Source" / "obj"
    if (obj / "libMPGO.so").is_file():
        return obj
    return None


# ------------------------------------------------------- ObjC → Python ---


@pytest.mark.parametrize(
    "filename,expected_title,expected_runs,expected_encrypted",
    [
        ("minimal_ms.mpgo", "minimal MS", ["run_0001"], False),
        ("full_ms.mpgo", "full MS with annotations", ["run_0001"], False),
        ("nmr_1d.mpgo", "NMR 1D example", ["nmr_run"], False),
        ("encrypted.mpgo", "encrypted example", ["run_0001"], True),
        ("signed.mpgo", "signed example", ["run_0001"], False),
    ],
)
def test_python_reads_every_objc_fixture(
    filename: str,
    expected_title: str,
    expected_runs: list[str],
    expected_encrypted: bool,
) -> None:
    path = _OBJC_FIXTURES / filename
    if not path.is_file():
        pytest.skip(f"missing fixture: {path}")

    with SpectralDataset.open(path) as ds:
        assert ds.feature_flags.version == "1.1"
        assert ds.title == expected_title
        assert list(ds.ms_runs.keys()) == expected_runs
        assert ds.is_encrypted == expected_encrypted
        for run_name in expected_runs:
            run = ds.ms_runs[run_name]
            assert len(run) >= 1
            # Touch one spectrum to force lazy reads along the full path
            first = run[0]
            if isinstance(first, MassSpectrum):
                assert first.mz_array.data.dtype == np.float64
            assert first.index == 0
            assert first.run_name == run_name


def test_python_reads_full_ms_compound_counts_match_readme() -> None:
    """The fixture README documents 10 identifications, 5 quantifications,
    and 2 provenance steps in ``full_ms.mpgo``. This test enforces those
    counts as a cross-implementation invariant."""
    p = _OBJC_FIXTURES / "full_ms.mpgo"
    if not p.is_file():
        pytest.skip(f"missing {p}")
    with SpectralDataset.open(p) as ds:
        assert len(ds.identifications()) == 10
        assert len(ds.quantifications()) == 5
        assert len(ds.provenance()) == 2


# ------------------------------------------------------- Python → ObjC ---


def _write_python_fixture(out: Path) -> None:
    n_spec, n_pts = 4, 6
    offsets = np.arange(n_spec, dtype=np.uint64) * n_pts
    lengths = np.full(n_spec, n_pts, dtype=np.uint32)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n_spec).astype(np.float64)
    intensity = np.tile(np.linspace(1.0, 1000.0, n_pts), n_spec).astype(np.float64)
    run = WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.linspace(0.0, 3.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 1000.0, dtype=np.float64),
    )
    idents = [
        Identification(run_name="run_0001", spectrum_index=0,
                       chemical_entity="CHEBI:17234",
                       confidence_score=0.42, evidence_chain=["MS:1002217"]),
        Identification(run_name="run_0001", spectrum_index=2,
                       chemical_entity="CHEBI:15377",
                       confidence_score=0.73, evidence_chain=["PRIDE:0000033"]),
    ]
    quants = [
        Quantification(chemical_entity="CHEBI:17234",
                       sample_ref="sample_A", abundance=1234.5,
                       normalization_method=""),
    ]
    prov = [
        ProvenanceRecord(timestamp_unix=1710000000, software="mpeg-o-py",
                         parameters={}, input_refs=[], output_refs=[]),
    ]
    SpectralDataset.write_minimal(
        out,
        title="py cross compat",
        isa_investigation_id="MPGO:pycc",
        runs={"run_0001": run},
        identifications=idents,
        quantifications=quants,
        provenance=prov,
    )


def test_round_trip_python_to_python(tmp_path: Path) -> None:
    """Fast sanity path that always runs: Python writer → Python reader."""
    out = tmp_path / "pycc.mpgo"
    _write_python_fixture(out)
    with SpectralDataset.open(out) as ds:
        assert ds.title == "py cross compat"
        assert list(ds.ms_runs.keys()) == ["run_0001"]
        assert len(ds.ms_runs["run_0001"]) == 4
        assert len(ds.identifications()) == 2
        assert len(ds.quantifications()) == 1
        assert len(ds.provenance()) == 1


@pytest.mark.skipif(_mpgo_verify_binary() is None,
                    reason="MpgoVerify CLI not built; build objc/Tools to enable")
def test_python_written_file_verifies_via_objc_cli(tmp_path: Path) -> None:
    """If the ObjC verifier is available, confirm it can parse a
    Python-written file and report matching field counts."""
    out = tmp_path / "pycc.mpgo"
    _write_python_fixture(out)
    binary = _mpgo_verify_binary()
    assert binary is not None
    env = os.environ.copy()
    lib_dir = _libmpgo_dir()
    if lib_dir is not None:
        existing = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = f"{lib_dir}:{existing}" if existing else str(lib_dir)
    res = subprocess.run(
        [str(binary), str(out)],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )
    report: dict[str, Any] = json.loads(res.stdout)
    assert report["title"] == "py cross compat"
    assert report["isa_investigation_id"] == "MPGO:pycc"
    assert report["ms_runs"]["run_0001"]["spectrum_count"] == 4
    assert report["identification_count"] == 2
    assert report["quantification_count"] == 1
    assert report["provenance_count"] == 1
