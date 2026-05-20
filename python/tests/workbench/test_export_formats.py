"""W6.4b -- ttio export --format expansion + GUI/CLI parity.

Mirror of test_encode_formats.py for the export side. Pins the format
set, the GUI parity contract, alias normalisation, and a pure-Python
mzML export round-trip.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.exporters import registry
from ttio.tools.workbench_cli import main

# The tio-browser ExportFormatRegistry, collapsed to its distinct
# writers (the GUI lists "mzML (indexed)", "FASTA (reference)" /
# "(reads)" variants that share one writer). Parity contract.
GUI_EXPORT_WRITERS = {
    "mzML", "mzTab", "imzML", "nmrML", "JCAMP-DX", "ISA-Tab/JSON",
    "BAM", "CRAM", "FASTA", "FASTQ",
}
# Python-side gap: these export from per-spectrum/pixel objects with no
# .tio-layer extraction helper yet.
PYTHON_DEFERRED = {"imzML", "nmrML", "JCAMP-DX"}


def test_supported_formats_set():
    assert set(registry.supported_export_formats()) == {
        "mzml", "mztab", "isa", "bam", "cram", "fasta", "fastq",
    }


def test_gui_cli_parity_modulo_documented_gaps():
    cli_display = {registry.spec_for(k).display_name
                   for k in registry.registry_keys()} | {"FASTA", "FASTQ"}
    assert GUI_EXPORT_WRITERS - cli_display == PYTHON_DEFERRED


@pytest.mark.parametrize("token,expected", [
    ("MZML", "mzml"),
    ("ISA-Tab", "isa"),
    ("isatab", "isa"),
    ("  BAM ", "bam"),
])
def test_alias_normalisation(token, expected):
    assert registry.normalize(token) == expected


def test_unknown_format_raises():
    with pytest.raises(registry.UnknownFormatError):
        registry.spec_for("ome-tiff")


def test_cli_unknown_format_exits_3(capsys):
    rc = main(["export", "--input", "x.tio", "--layer", "run_0001",
               "--format", "xyz", "--output", "out.bin"])
    assert rc == 3
    err = capsys.readouterr().err
    assert "unsupported --format" in err
    assert "nmrML" in err  # documents the gap


def test_cram_requires_reference(tmp_path):
    src = _write_ms_tio(tmp_path)
    with pytest.raises(Exception):
        # No --reference -> the adapter raises before touching samtools.
        registry.export("cram", src, None, str(tmp_path / "o.cram"))


def _write_ms_tio(tmp_path: Path) -> str:
    src = tmp_path / "src.tio"
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={
            "mz": np.tile(np.linspace(100.0, 102.5, 6), 3).astype(np.float64),
            "intensity": np.tile(np.linspace(1.0, 100.0, 6), 3).astype(np.float64),
        },
        offsets=np.arange(3, dtype=np.uint64) * 6,
        lengths=np.full(3, 6, dtype=np.uint32),
        retention_times=np.linspace(0.0, 2.0, 3, dtype=np.float64),
        ms_levels=np.ones(3, dtype=np.int32),
        polarities=np.ones(3, dtype=np.int32),
        precursor_mzs=np.zeros(3, dtype=np.float64),
        precursor_charges=np.zeros(3, dtype=np.int32),
        base_peak_intensities=np.full(3, 100.0, dtype=np.float64),
    )
    SpectralDataset.write_minimal(
        src, title="w64b", isa_investigation_id="TTIO:w64b",
        runs={"run_0001": run})
    return str(src)


def test_registry_mzml_export_round_trip(tmp_path):
    src = _write_ms_tio(tmp_path)
    out = tmp_path / "out.mzML"
    registry.export("mzml", src, "run_0001", str(out))
    assert out.exists() and out.stat().st_size > 0
    from ttio.importers import mzml as mzml_reader
    result = mzml_reader.read(out)
    assert len(result.ms_spectra) == 3


def test_cli_export_mzml(tmp_path, capsys):
    src = _write_ms_tio(tmp_path)
    out = tmp_path / "cli.mzML"
    rc = main(["export", "--input", src, "--layer", "run_0001",
               "--format", "mzml", "--output", str(out)])
    assert rc == 0
    assert out.exists()
    assert "exported" in capsys.readouterr().out


def test_registry_isa_export(tmp_path):
    src = _write_ms_tio(tmp_path)
    out_dir = tmp_path / "isa_bundle"
    registry.export("isa", src, None, str(out_dir))
    assert out_dir.is_dir()
    assert any(out_dir.iterdir())  # bundle wrote at least one file
