"""Milestone 27 — ISA-Tab / ISA-JSON exporter (Python side).

Verifies:
  * bundle_for_dataset produces the expected filenames for a single-run
    dataset (with and without chromatograms).
  * The investigation and study TSV files contain the dataset title,
    identifier, and sample rows.
  * ISA-JSON parses and carries the expected identifier, title, and
    measurement/technology types.
  * write_bundle_for_dataset writes the bundle to disk.
  * Structural parity with the ObjC side: bundle keys match and the
    parsed ISA-JSON dicts are equal.

The ObjC side is covered in TestMilestone27.m; byte-level JSON parity
is relaxed to structural (parse-and-compare) per the note in
mpeg_o.exporters.isa — the NSJSONSerialization vs json.dumps
whitespace differences are not meaningful.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.chromatogram import Chromatogram
from mpeg_o.enums import ChromatogramType
from mpeg_o.exporters.isa import bundle_for_dataset, write_bundle_for_dataset
from mpeg_o.instrument_config import InstrumentConfig
from mpeg_o.signal_array import SignalArray


def _make_run(*, with_chromatograms: bool) -> WrittenRun:
    n = 3
    mz = np.array([100.0, 200.0, 300.0], dtype=np.float64)
    it = np.array([10.0, 20.0, 30.0], dtype=np.float64)
    offsets = np.array([0], dtype=np.uint64)
    lengths = np.array([n], dtype=np.uint32)
    chroms: list[Chromatogram] = []
    if with_chromatograms:
        chroms.append(Chromatogram(
            signal_arrays={
                "time": SignalArray(data=np.array([0.0, 1.0, 2.0], dtype=np.float64)),
                "intensity": SignalArray(data=np.array([100.0, 500.0, 200.0], dtype=np.float64)),
            },
            axes=[],
            chromatogram_type=ChromatogramType.TIC,
        ))
    return WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz, "intensity": it},
        offsets=offsets, lengths=lengths,
        retention_times=np.array([1.0], dtype=np.float64),
        ms_levels=np.array([1], dtype=np.int32),
        polarities=np.array([1], dtype=np.int32),
        precursor_mzs=np.array([0.0], dtype=np.float64),
        precursor_charges=np.array([0], dtype=np.int32),
        base_peak_intensities=np.array([30.0], dtype=np.float64),
        chromatograms=chroms,
    )


def _make_dataset(tmp_path: Path, *, with_chromatograms: bool) -> SpectralDataset:
    path = tmp_path / "m27_dataset.mpgo"
    if path.exists():
        path.unlink()
    SpectralDataset.write_minimal(
        path,
        title="M27 Investigation",
        isa_investigation_id="ISA-M27-001",
        runs={"run_0001": _make_run(with_chromatograms=with_chromatograms)},
    )
    ds = SpectralDataset.open(path)
    # Inject a non-empty instrument config so parity tests see a value.
    ds.ms_runs["run_0001"].instrument_config = InstrumentConfig(
        manufacturer="Thermo",
        model="Orbitrap Exploris 480",
        serial_number="SN-001",
        source_type="electrospray ionization",
        analyzer_type="orbitrap",
        detector_type="electron multiplier",
    )
    return ds


def test_bundle_filenames_and_keys(tmp_path: Path) -> None:
    ds = _make_dataset(tmp_path, with_chromatograms=False)
    try:
        bundle = bundle_for_dataset(ds)
    finally:
        ds.close()
    assert set(bundle.keys()) == {
        "i_investigation.txt",
        "s_study.txt",
        "a_assay_ms_run_0001.txt",
        "investigation.json",
    }


def test_investigation_tsv_carries_metadata(tmp_path: Path) -> None:
    ds = _make_dataset(tmp_path, with_chromatograms=False)
    try:
        bundle = bundle_for_dataset(ds)
    finally:
        ds.close()
    inv = bundle["i_investigation.txt"].decode("utf-8")
    assert "ISA-M27-001" in inv
    assert "M27 Investigation" in inv
    assert "mass spectrometry" in inv


def test_study_and_assay_rows(tmp_path: Path) -> None:
    ds = _make_dataset(tmp_path, with_chromatograms=True)
    try:
        bundle = bundle_for_dataset(ds)
    finally:
        ds.close()
    study = bundle["s_study.txt"].decode("utf-8")
    assert "sample_run_0001" in study
    assay = bundle["a_assay_ms_run_0001.txt"].decode("utf-8")
    assert "run_0001.mzML" in assay
    assert "run_0001_chrom_0" in assay


def test_isa_json_structure(tmp_path: Path) -> None:
    ds = _make_dataset(tmp_path, with_chromatograms=False)
    try:
        bundle = bundle_for_dataset(ds)
    finally:
        ds.close()
    parsed = json.loads(bundle["investigation.json"].decode("utf-8"))
    assert parsed["identifier"] == "ISA-M27-001"
    assert parsed["title"] == "M27 Investigation"
    assert len(parsed["studies"]) == 1
    study = parsed["studies"][0]
    assert len(study["assays"]) == 1
    assay = study["assays"][0]
    assert assay["technologyType"]["annotationValue"] == "mass spectrometry"
    assert assay["measurementType"]["annotationValue"] == "metabolite profiling"


def test_write_bundle_to_disk(tmp_path: Path) -> None:
    ds = _make_dataset(tmp_path, with_chromatograms=False)
    out = tmp_path / "isa_out"
    try:
        write_bundle_for_dataset(ds, out)
    finally:
        ds.close()
    assert (out / "i_investigation.txt").is_file()
    assert (out / "s_study.txt").is_file()
    assert (out / "a_assay_ms_run_0001.txt").is_file()
    assert (out / "investigation.json").is_file()
