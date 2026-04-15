"""M19 mzML writer tests — round trip and byte offsets."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.enums import AcquisitionMode
from mpeg_o.exporters import mzml as mzml_writer
from mpeg_o.importers import mzml as mzml_reader


def _build_dataset(n_spec: int = 3, n_pts: int = 6) -> Path:
    return WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={
            "mz": np.tile(np.linspace(100.0, 102.5, n_pts), n_spec).astype(np.float64),
            "intensity": np.tile(np.linspace(1.0, 100.0, n_pts), n_spec).astype(np.float64),
        },
        offsets=np.arange(n_spec, dtype=np.uint64) * n_pts,
        lengths=np.full(n_spec, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 2.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 100.0, dtype=np.float64),
    )


def _write_mpgo(tmp_path: Path, n_spec: int = 3, n_pts: int = 6) -> Path:
    out = tmp_path / "m19_src.mpgo"
    SpectralDataset.write_minimal(
        out, title="m19", isa_investigation_id="MPGO:m19",
        runs={"run_0001": _build_dataset(n_spec=n_spec, n_pts=n_pts)},
    )
    return out


def test_writer_produces_parseable_mzml_uncompressed(tmp_path: Path) -> None:
    src = _write_mpgo(tmp_path, n_spec=3, n_pts=6)
    mzml_path = tmp_path / "out.mzML"
    with SpectralDataset.open(src) as ds:
        mzml_writer.write_dataset(ds, mzml_path, zlib_compression=False)
    assert mzml_path.stat().st_size > 0

    # Round trip via the mpeg_o mzML importer.
    result = mzml_reader.read(mzml_path)
    assert len(result.ms_spectra) == 3
    first = result.ms_spectra[0]
    np.testing.assert_allclose(
        first.mz_or_chemical_shift, np.linspace(100.0, 102.5, 6),
    )
    np.testing.assert_allclose(
        first.intensity, np.linspace(1.0, 100.0, 6),
    )


def test_writer_produces_parseable_mzml_zlib(tmp_path: Path) -> None:
    src = _write_mpgo(tmp_path, n_spec=4, n_pts=8)
    mzml_path = tmp_path / "out.mzML"
    with SpectralDataset.open(src) as ds:
        mzml_writer.write_dataset(ds, mzml_path, zlib_compression=True)

    result = mzml_reader.read(mzml_path)
    assert len(result.ms_spectra) == 4
    # Exact float64 equality after zlib round trip.
    last = result.ms_spectra[3]
    np.testing.assert_array_equal(
        last.mz_or_chemical_shift.astype(np.float64),
        np.linspace(100.0, 102.5, 8).astype(np.float64),
    )


def test_indexed_mzml_offsets_point_at_spectrum_tag(tmp_path: Path) -> None:
    """``<indexList>`` offsets must be byte-correct — the byte at each
    offset should be the literal ``<`` of ``<spectrum``."""
    src = _write_mpgo(tmp_path, n_spec=2, n_pts=4)
    with SpectralDataset.open(src) as ds:
        blob = mzml_writer.dataset_to_bytes(ds, zlib_compression=False)

    text = blob.decode("utf-8")
    # Parse the first <offset> entry under the spectrum index.
    start = text.index('<index name="spectrum">')
    offset_line = text.index('<offset idRef="scan=1">', start)
    num_start = offset_line + len('<offset idRef="scan=1">')
    num_end = text.index("</offset>", num_start)
    byte_offset = int(text[num_start:num_end])

    assert 0 < byte_offset < len(blob)
    snippet = blob[byte_offset:byte_offset + len("<spectrum")]
    assert snippet == b"<spectrum"


def test_writer_refuses_dataset_without_ms_run(tmp_path: Path) -> None:
    out = tmp_path / "empty.mpgo"
    # Build a valid .mpgo with a single NMR-class run so there is no
    # MPGOMassSpectrum to export.
    SpectralDataset.write_minimal(
        out, title="nmr only", isa_investigation_id="MPGO:nmr",
        runs={"nmr_run": WrittenRun(
            spectrum_class="MPGONMRSpectrum",
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
        )},
    )
    with SpectralDataset.open(out) as ds:
        with pytest.raises(ValueError, match="no MPGOMassSpectrum"):
            mzml_writer.dataset_to_bytes(ds)
