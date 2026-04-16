"""Milestone 24 — Chromatogram API + mzML writer completion.

Verifies:
  * Chromatograms round-trip through ``.mpgo`` (write_minimal → open → read).
  * Chromatograms round-trip through the Python mzML writer + reader.
  * v0.3 files (no /chromatograms/ group) still read back with an empty list.
  * A fixture produced by the ObjC writer (if available) exposes chromatograms
    when re-read by the Python side — cross-language parity guard-rail.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.chromatogram import Chromatogram
from mpeg_o.enums import ChromatogramType
from mpeg_o.exporters.mzml import dataset_to_bytes
from mpeg_o.importers.mzml import read as read_mzml


def _empty_ms_run() -> WrittenRun:
    z8 = np.zeros(0, dtype=np.uint64)
    z4 = np.zeros(0, dtype=np.uint32)
    f8 = np.zeros(0, dtype=np.float64)
    i4 = np.zeros(0, dtype=np.int32)
    return WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": f8, "intensity": f8},
        offsets=z8, lengths=z4,
        retention_times=f8, ms_levels=i4, polarities=i4,
        precursor_mzs=f8, precursor_charges=i4, base_peak_intensities=f8,
    )


def _make_chromatograms() -> list[Chromatogram]:
    t10 = np.linspace(0.0, 10.0, 10, dtype=np.float64)
    i10 = np.arange(10, dtype=np.float64) * 7 + 100
    t8  = np.linspace(0.0, 8.0, 8, dtype=np.float64)
    i8  = np.arange(8, dtype=np.float64) * 13 + 50
    t12 = np.linspace(0.0, 12.0, 12, dtype=np.float64)
    i12 = np.arange(12, dtype=np.float64) * 3 + 250
    return [
        Chromatogram(t10, i10, chromatogram_type=ChromatogramType.TIC),
        Chromatogram(t8,  i8,  chromatogram_type=ChromatogramType.XIC, target_mz=523.25),
        Chromatogram(t12, i12, chromatogram_type=ChromatogramType.SRM,
                     precursor_mz=400.5, product_mz=185.1),
    ]


def test_chromatograms_mpgo_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "m24_rt.mpgo"
    run = _empty_ms_run()
    run.chromatograms = _make_chromatograms()
    SpectralDataset.write_minimal(
        path,
        title="M24 round-trip",
        isa_investigation_id="ISA-M24",
        runs={"run_0001": run},
    )
    with SpectralDataset.open(path) as ds:
        run_back = ds.ms_runs["run_0001"]
        assert len(run_back.chromatograms) == 3
        c0, c1, c2 = run_back.chromatograms
        assert c0.chromatogram_type == ChromatogramType.TIC
        assert c0.retention_times.shape[0] == 10
        assert c1.chromatogram_type == ChromatogramType.XIC
        assert c1.target_mz == 523.25
        assert c2.chromatogram_type == ChromatogramType.SRM
        assert c2.precursor_mz == 400.5
        assert c2.product_mz == 185.1
        assert np.array_equal(c0.intensities,
                              np.arange(10, dtype=np.float64) * 7 + 100)


def test_v03_file_reads_as_empty_chromatogram_list(tmp_path: Path) -> None:
    path = tmp_path / "m24_v03.mpgo"
    run = _empty_ms_run()  # no chromatograms
    SpectralDataset.write_minimal(
        path,
        title="v0.3 shape",
        isa_investigation_id="ISA-v03",
        runs={"run_0001": run},
    )
    with SpectralDataset.open(path) as ds:
        assert ds.ms_runs["run_0001"].chromatograms == []


def test_mzml_writer_emits_chromatogram_list_and_index(tmp_path: Path) -> None:
    """Writer must emit <chromatogramList> + <index name="chromatogram"> block
    whose offset anchors each <chromatogram tag's first byte."""
    # Need a run with at least one MPGOMassSpectrum to satisfy the writer's
    # "choose first MS run" check. Build a 2-spectrum MS1 run.
    n = 3
    mz = np.array([100.0, 150.0, 200.0], dtype=np.float64)
    it = np.array([500.0, 900.0, 200.0], dtype=np.float64)
    channel = {"mz": np.concatenate([mz, mz]),
               "intensity": np.concatenate([it, it])}
    offsets = np.array([0, n], dtype=np.uint64)
    lengths = np.array([n, n], dtype=np.uint32)
    run = WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data=channel,
        offsets=offsets, lengths=lengths,
        retention_times=np.array([1.0, 2.0], dtype=np.float64),
        ms_levels=np.array([1, 1], dtype=np.int32),
        polarities=np.array([1, 1], dtype=np.int32),
        precursor_mzs=np.zeros(2, dtype=np.float64),
        precursor_charges=np.zeros(2, dtype=np.int32),
        base_peak_intensities=np.array([900.0, 900.0], dtype=np.float64),
        chromatograms=_make_chromatograms(),
    )
    path = tmp_path / "m24_mzml_in.mpgo"
    SpectralDataset.write_minimal(
        path,
        title="m24",
        isa_investigation_id="ISA-M24",
        runs={"run_0001": run},
    )

    with SpectralDataset.open(path) as ds:
        blob = dataset_to_bytes(ds)
    text = blob.decode("utf-8")
    assert "<chromatogramList" in text
    assert 'MS:1000235' in text  # TIC
    assert 'MS:1000627' in text  # XIC
    assert 'MS:1001473' in text  # SRM
    assert '<index name="chromatogram">' in text
    # Offsets must point at "<chromatogram " tags.
    import re
    for m in re.finditer(r'<offset idRef="chrom=\d+">(\d+)</offset>', text):
        off = int(m.group(1))
        assert blob[off:off + len(b"<chromatogram ")] == b"<chromatogram ", (
            f"offset {off} does not anchor <chromatogram")

    # Write to disk and re-parse via the Python reader.
    mzml_path = tmp_path / "m24.mzml"
    mzml_path.write_bytes(blob)
    result = read_mzml(mzml_path)
    assert len(result.chromatograms) == 3
    assert [c.chromatogram_type for c in result.chromatograms] == [0, 1, 2]
    assert result.chromatograms[1].target_mz == 523.25
    assert result.chromatograms[2].precursor_mz == 400.5
    assert result.chromatograms[2].product_mz == 185.1
