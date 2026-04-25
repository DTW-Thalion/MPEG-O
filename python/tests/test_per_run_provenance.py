"""M17 cross-implementation tests: compound per-run provenance.

Covers both the reader-side (Python opens ObjC-written files that carry
the v0.3 compound layout or the v0.2 ``@provenance_json`` legacy mirror)
and the writer-side (Python-written files round-trip through the Python
reader and carry the ``compound_per_run_provenance`` feature flag).
"""
from __future__ import annotations

import json
from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio import (
    ProvenanceRecord,
    SpectralDataset,
    WrittenRun,
)
from ttio import _hdf5_io as io
from ttio.enums import AcquisitionMode


def _run_with_prov(records: list[ProvenanceRecord]) -> WrittenRun:
    n_spec, n_pts = 3, 4
    offsets = np.arange(n_spec, dtype=np.uint64) * n_pts
    lengths = np.full(n_spec, n_pts, dtype=np.uint32)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n_spec).astype(np.float64)
    intensity = np.tile(np.linspace(1.0, 100.0, n_pts), n_spec).astype(np.float64)
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.linspace(0.0, 2.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 100.0, dtype=np.float64),
        provenance_records=records,
    )


def _make_records() -> list[ProvenanceRecord]:
    return [
        ProvenanceRecord(
            timestamp_unix=1710000000, software="thermo-raw-parser/1.4",
            parameters={"denoise": "yes"},
            input_refs=["raw:run_0001"], output_refs=["ttio:run_0001"],
        ),
        ProvenanceRecord(
            timestamp_unix=1710000100, software="ttio-py/0.3.0",
            parameters={"mode": "serialize"},
            input_refs=["ttio:run_0001"], output_refs=["ttio:run_0001"],
        ),
    ]


def test_python_writer_emits_compound_per_run_provenance(tmp_path: Path) -> None:
    out = tmp_path / "m17_compound.tio"
    records = _make_records()
    SpectralDataset.write_minimal(
        out,
        title="m17 compound",
        isa_investigation_id="TTIO:m17",
        runs={"run_0001": _run_with_prov(records)},
    )
    # Inspect raw HDF5: compound subgroup + legacy mirror + feature flag
    with h5py.File(out, "r") as f:
        _, features = io.read_feature_flags(f)
        assert "compound_per_run_provenance" in features
        run = f["study/ms_runs/run_0001"]
        assert "provenance" in run and "steps" in run["provenance"]
        assert "provenance_json" in run.attrs  # legacy mirror


def test_python_reader_decodes_compound_per_run_provenance(tmp_path: Path) -> None:
    out = tmp_path / "m17_read.tio"
    records = _make_records()
    SpectralDataset.write_minimal(
        out,
        title="m17 read",
        isa_investigation_id="TTIO:m17r",
        runs={"run_0001": _run_with_prov(records)},
    )
    with SpectralDataset.open(out) as ds:
        run = ds.ms_runs["run_0001"]
        out_prov = run.provenance()
        assert len(out_prov) == 2
        assert out_prov[0].software == "thermo-raw-parser/1.4"
        assert out_prov[0].timestamp_unix == 1710000000
        assert out_prov[0].parameters == {"denoise": "yes"}
        assert out_prov[1].software == "ttio-py/0.3.0"


def test_python_reader_falls_back_to_legacy_json(tmp_path: Path) -> None:
    """Simulate a v0.2 file: write via the compound path, then manually
    delete the compound subgroup. The reader must still recover the
    records via the ``@provenance_json`` attribute."""
    out = tmp_path / "m17_legacy.tio"
    records = _make_records()
    SpectralDataset.write_minimal(
        out,
        title="m17 legacy",
        isa_investigation_id="TTIO:m17l",
        runs={"run_0001": _run_with_prov(records)},
    )
    # Remove the compound form in-place.
    with h5py.File(out, "r+") as f:
        del f["study/ms_runs/run_0001/provenance"]
        assert "provenance" not in f["study/ms_runs/run_0001"]
        assert "provenance_json" in f["study/ms_runs/run_0001"].attrs

    with SpectralDataset.open(out) as ds:
        run = ds.ms_runs["run_0001"]
        out_prov = run.provenance()
        assert len(out_prov) == 2
        assert out_prov[0].software == "thermo-raw-parser/1.4"
        assert out_prov[0].timestamp_unix == 1710000000
        assert out_prov[1].software == "ttio-py/0.3.0"


def test_run_without_provenance_omits_subgroup(tmp_path: Path) -> None:
    out = tmp_path / "m17_empty.tio"
    SpectralDataset.write_minimal(
        out,
        title="m17 empty",
        isa_investigation_id="TTIO:m17e",
        runs={"run_0001": _run_with_prov([])},
    )
    with h5py.File(out, "r") as f:
        run = f["study/ms_runs/run_0001"]
        assert "provenance" not in run
        assert "provenance_json" not in run.attrs
    with SpectralDataset.open(out) as ds:
        assert ds.ms_runs["run_0001"].provenance() == []
