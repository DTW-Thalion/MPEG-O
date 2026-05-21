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


def test_supported_formats_set():
    assert set(registry.supported_export_formats()) == {
        "mzml", "mztab", "nmrml", "imzml", "jcamp-dx", "isa", "bam", "cram",
        "fasta", "fastq",
    }


def test_gui_cli_parity():
    cli_display = {registry.spec_for(k).display_name
                   for k in registry.registry_keys()} | {"FASTA", "FASTQ"}
    # JCAMP-DX export gap closed by the vibrational .tio round-trip.
    assert GUI_EXPORT_WRITERS - cli_display == set()


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


def _write_nmr_tio(tmp_path: Path) -> str:
    src = tmp_path / "nmr.tio"
    run = WrittenRun(
        spectrum_class="TTIONMRSpectrum",
        acquisition_mode=int(AcquisitionMode.NMR_1D),
        channel_data={
            "chemical_shift": np.linspace(0.0, 10.0, 8),
            "intensity": np.linspace(1.0, 8.0, 8),
        },
        offsets=np.array([0], dtype=np.uint64),
        lengths=np.array([8], dtype=np.uint32),
        retention_times=np.array([0.0]),
        ms_levels=np.zeros(1, dtype=np.int32),
        polarities=np.zeros(1, dtype=np.int32),
        precursor_mzs=np.zeros(1),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=np.array([10.0]),
        nucleus_type="1H",
    )
    SpectralDataset.write_minimal(
        src, title="nmr", isa_investigation_id="TTIO:nmr",
        runs={"nmr_run": run})
    return str(src)


def test_registry_nmrml_export(tmp_path):
    src = _write_nmr_tio(tmp_path)
    out = tmp_path / "out.nmrML"
    registry.export("nmrml", src, "nmr_run", str(out))
    assert out.exists() and out.stat().st_size > 0
    from ttio.importers import nmrml as nmrml_reader
    assert nmrml_reader.read(out) is not None  # round-trips through the reader


def _write_image_tio(tmp_path: Path) -> str:
    from ttio.ms_image import MSImage
    src = tmp_path / "img.tio"
    h, w, p = 2, 3, 4
    intensity = np.arange(h * w * p, dtype=np.float64).reshape(h, w, p)
    mz_axis = np.linspace(100.0, 110.0, p)
    img = MSImage(width=w, height=h, spectral_points=p,
                  intensity=intensity, mz_axis=mz_axis)
    SpectralDataset.write_minimal(
        src, title="img", isa_investigation_id="TTIO:img",
        runs={}, image=img)
    return str(src)


def test_registry_imzml_export(tmp_path):
    src = _write_image_tio(tmp_path)
    out = tmp_path / "out.imzML"
    registry.export("imzml", src, None, str(out))
    assert out.exists() and out.stat().st_size > 0
    assert out.with_suffix(".ibd").exists()  # imzML + .ibd pair
