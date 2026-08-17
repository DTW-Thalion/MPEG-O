"""Tests for the Thermo .raw importer — M38 delegation.

The importer shells out to ThermoRawFileParser. These tests use a
mock binary (bash script) that copies a known mzML fixture to the
expected output path, so CI does not depend on the real parser.
"""
from __future__ import annotations

import os
import stat
from pathlib import Path

import pytest

from ttio.importers import ImportResult, thermo_raw


_REPO_ROOT = Path(__file__).resolve().parents[2]
_XML_FIXTURE_DIR = _REPO_ROOT / "objc" / "Tests" / "Fixtures"


@pytest.fixture(scope="module")
def tiny_mzml() -> Path:
    p = _XML_FIXTURE_DIR / "tiny.pwiz.1.1.mzML"
    if not p.is_file():
        pytest.skip(f"missing {p}")
    return p


@pytest.fixture
def mock_parser(tmp_path: Path, tiny_mzml: Path) -> Path:
    """Bash script that emulates ThermoRawFileParser's `-i -o -f 2` CLI."""
    script = tmp_path / "mock-parser"
    script.write_text(
        "#!/usr/bin/env bash\n"
        "set -e\n"
        "while [ $# -gt 0 ]; do\n"
        '  case "$1" in\n'
        "    -i) in_path=\"$2\"; shift 2;;\n"
        "    -o) out_dir=\"$2\"; shift 2;;\n"
        "    -f) format=\"$2\"; shift 2;;\n"
        "    *) shift;;\n"
        "  esac\n"
        "done\n"
        'base=$(basename "$in_path" .raw)\n'
        'cp ' + str(tiny_mzml) + ' "$out_dir/$base.mzML"\n'
    )
    script.chmod(script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return script


def test_reads_via_mock_parser(tmp_path: Path, mock_parser: Path) -> None:
    raw = tmp_path / "sample.raw"
    raw.write_bytes(b"fake raw bytes")

    result = thermo_raw.read(raw, thermorawfileparser=str(mock_parser))
    assert isinstance(result, ImportResult)
    assert result.spectrum_count > 0


def test_missing_binary_raises_clear_error(tmp_path: Path) -> None:
    raw = tmp_path / "sample.raw"
    raw.write_bytes(b"fake")

    with pytest.raises(FileNotFoundError) as ex:
        thermo_raw.read(raw, thermorawfileparser=str(tmp_path / "does-not-exist"))
    assert "ThermoRawFileParser" in str(ex.value) or "thermoraw" in str(ex.value).lower()


def test_env_var_override(tmp_path: Path, mock_parser: Path,
                           monkeypatch: pytest.MonkeyPatch) -> None:
    raw = tmp_path / "env.raw"
    raw.write_bytes(b"fake")

    monkeypatch.setenv("THERMORAWFILEPARSER", str(mock_parser))
    result = thermo_raw.read(raw)  # no explicit arg
    assert isinstance(result, ImportResult)
    assert result.spectrum_count > 0


def test_nonzero_exit_raises(tmp_path: Path) -> None:
    failing = tmp_path / "failing-parser"
    failing.write_text("#!/usr/bin/env bash\nexit 7\n")
    failing.chmod(failing.stat().st_mode | stat.S_IXUSR)

    raw = tmp_path / "sample.raw"
    raw.write_bytes(b"fake")

    with pytest.raises(RuntimeError) as ex:
        thermo_raw.read(raw, thermorawfileparser=str(failing))
    msg = str(ex.value)
    assert "ThermoRawFileParser" in msg or "7" in msg


def test_stream_source_via_mock_parser(tmp_path: Path, mock_parser: Path,
                                       monkeypatch: pytest.MonkeyPatch) -> None:
    """stream_source converts through the parser and streams the mzML;
    the temporary directory is gone once the stream is exhausted."""
    from ttio.spectral_dataset import SpectralDataset

    raw = tmp_path / "sample.raw"
    raw.write_bytes(b"fake raw bytes")
    src = thermo_raw.stream_source(raw, thermorawfileparser=str(mock_parser), batch_spectra=3)
    batches = list(src.iter_batches())
    n = sum(int(b.offsets.shape[0]) for b in batches)
    assert n > 0 and len(batches) == (n + 2) // 3
    out = tmp_path / "o.tio"
    SpectralDataset.write_minimal(out, title="t", isa_investigation_id="i", runs={})
    with SpectralDataset.open(out, writable=True) as ds:
        assert src.write_into(ds.study_group) == n
    with SpectralDataset.open(out) as ds:
        assert len(ds.all_runs["run_0001"]) == n
    # registry path (resolves the parser through the env override)
    monkeypatch.setenv("THERMORAWFILEPARSER", str(mock_parser))
    from ttio.importers import readers
    draft = readers.ThermoRawReader().read([str(raw)], {})
    assert "run_0001" in draft.spectral_streams


def test_stream_source_missing_raw_raises(tmp_path: Path, mock_parser: Path) -> None:
    with pytest.raises(FileNotFoundError):
        thermo_raw.stream_source(tmp_path / "nope.raw", thermorawfileparser=str(mock_parser))


def test_stream_source_parser_failure_raises(tmp_path: Path) -> None:
    failing = tmp_path / "failing"
    failing.write_text("#!/usr/bin/env bash\nexit 3\n")
    failing.chmod(failing.stat().st_mode | stat.S_IXUSR)
    raw = tmp_path / "s.raw"
    raw.write_bytes(b"fake")
    src = thermo_raw.stream_source(raw, thermorawfileparser=str(failing))
    with pytest.raises(RuntimeError, match="exited 3"):
        list(src.iter_batches())
