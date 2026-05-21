"""W6.4a -- ttio encode --format expansion + GUI/CLI parity.

The registry is the single source of truth for the CLI's encode
formats; these tests pin the format set, the GUI parity contract, the
alias normalisation, and one pure-Python round-trip (mzML).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.importers import registry
from ttio.tools.workbench_cli import main

# The tio-browser GUI ImportFormatRegistry display names (the parity
# contract). If the GUI adds/renames a format, update this list
# deliberately + extend the Python registry to match.
GUI_FORMATS = {
    "mzML", "mzTab", "imzML", "nmrML", "JCAMP-DX", "Bruker timsTOF",
    "Waters MassLynx", "Thermo .raw", "BAM", "SAM", "CRAM", "FASTA", "FASTQ",
}


def test_supported_formats_set():
    assert set(registry.supported_encode_formats()) == {
        "mzml", "mztab", "imzml", "nmrml", "jcamp-dx", "bam", "sam", "cram",
        "thermo-raw", "waters-masslynx", "bruker-timstof",
        "fasta", "fastq",
    }


def test_gui_cli_parity():
    cli_display = {registry.spec_for(k).display_name
                   for k in registry.registry_keys()} | {"FASTA", "FASTQ"}
    # Every GUI format is now reachable from the CLI (JCAMP-DX gap closed
    # by the vibrational .tio round-trip).
    assert GUI_FORMATS - cli_display == set()


@pytest.mark.parametrize("token,expected", [
    ("MZML", "mzml"),
    ("thermo", "thermo-raw"),
    ("raw", "thermo-raw"),
    ("waters", "waters-masslynx"),
    ("masslynx", "waters-masslynx"),
    ("bruker", "bruker-timstof"),
    ("timstof", "bruker-timstof"),
    ("  Bam ", "bam"),
])
def test_alias_normalisation(token, expected):
    assert registry.normalize(token) == expected


def test_unknown_format_raises():
    with pytest.raises(registry.UnknownFormatError):
        registry.spec_for("ome-tiff")


def test_cli_unknown_format_exits_3(capsys):
    rc = main(["encode", "--input", "x.xyz", "--format", "xyz",
               "--output", "out.tio"])
    assert rc == 3
    err = capsys.readouterr().err
    assert "unsupported --format" in err


def test_cli_bam_is_recognised_not_unsupported(capsys, tmp_path):
    # bam is a known codec now; with a missing input it should fail at
    # the importer (rc 2), NOT report "unsupported --format" (rc 3).
    rc = main(["encode", "--input", str(tmp_path / "missing.bam"),
               "--format", "bam", "--output", str(tmp_path / "o.tio")])
    assert rc == 2
    assert "unsupported --format" not in capsys.readouterr().err


def _write_mzml(tmp_path: Path) -> Path:
    from ttio.exporters import mzml as mzml_writer
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
        src, title="w64", isa_investigation_id="TTIO:w64",
        runs={"run_0001": run})
    mzml_path = tmp_path / "sample.mzML"
    with SpectralDataset.open(src) as ds:
        mzml_writer.write_dataset(ds, mzml_path, zlib_compression=False)
    return mzml_path


def test_registry_mzml_round_trip(tmp_path):
    mzml_path = _write_mzml(tmp_path)
    out = tmp_path / "encoded.tio"
    registry.encode("mzml", [mzml_path], out)
    assert out.exists()
    with SpectralDataset.open(out) as ds:
        assert ds.ms_runs  # at least one MS run materialised


def test_cli_encode_mzml_round_trip(tmp_path, capsys):
    mzml_path = _write_mzml(tmp_path)
    out = tmp_path / "cli.tio"
    rc = main(["encode", "--input", str(mzml_path), "--format", "mzml",
               "--output", str(out)])
    assert rc == 0
    assert out.exists()
    assert "encoded" in capsys.readouterr().out
