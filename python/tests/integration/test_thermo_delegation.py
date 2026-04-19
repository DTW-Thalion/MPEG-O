"""Thermo .raw → .mpgo delegation integration test (v0.9 M58).

The Thermo importer shells out to user-installed
``ThermoRawFileParser``; full execution requires the binary on PATH.
The CI default filter (``-m "not requires_thermorawfileparser"``)
skips this file unless the binary is present, but we also assert the
clear-error contract when it is not — that path is always exercisable.
"""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from mpeg_o import SpectralDataset
from mpeg_o.importers import thermo_raw


THERMO_BIN = shutil.which("ThermoRawFileParser") or shutil.which("thermorawfileparser")


def test_missing_binary_raises_clear_error(tmp_path: Path) -> None:
    """When the binary is unresolvable the importer surfaces a
    FileNotFoundError pointing at the install docs."""
    fake_raw = tmp_path / "missing.raw"
    fake_raw.touch()
    with pytest.raises(FileNotFoundError):
        thermo_raw.read(fake_raw, thermorawfileparser="/nonexistent/no-such-trfp-binary")


def test_missing_input_raises_filenotfound(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        thermo_raw.read(tmp_path / "does-not-exist.raw")


@pytest.mark.requires_thermorawfileparser
def test_thermo_raw_to_mpgo_delegation(tmp_path: Path) -> None:
    """End-to-end: tiny .raw → ImportResult → .mpgo → verify spectra count.

    Skipped automatically (per conftest) when ThermoRawFileParser is
    not available. A user-supplied fixture is also required —
    accepting the env var ``MPGO_THERMO_RAW_FIXTURE``.
    """
    import os
    fixture_env = os.environ.get("MPGO_THERMO_RAW_FIXTURE")
    if not fixture_env:
        pytest.skip("MPGO_THERMO_RAW_FIXTURE not set; no real Thermo .raw available")
    raw = Path(fixture_env)
    if not raw.is_file():
        pytest.skip(f"MPGO_THERMO_RAW_FIXTURE={raw} not found")

    result = thermo_raw.read(raw)
    assert result.spectrum_count > 0
    out = tmp_path / "thermo.mpgo"
    result.to_mpgo(out)
    with SpectralDataset.open(out) as ds:
        runs = list(ds.ms_runs.values())
        assert runs
        total = sum(len(r) for r in runs)
        assert total == result.spectrum_count
