from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.importers.base import Reader
from ttio.importers.imported_dataset import ImportedDataset
from ttio.importers import readers


def _write_mzml(tmp_path: Path) -> Path:
    from ttio.exporters import mzml as w
    src = tmp_path / "s.tio"
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": np.tile(np.linspace(100.0, 102.5, 6), 3),
                      "intensity": np.tile(np.linspace(1.0, 100.0, 6), 3)},
        offsets=np.arange(3, dtype=np.uint64) * 6,
        lengths=np.full(3, 6, dtype=np.uint32),
        retention_times=np.linspace(0.0, 2.0, 3, dtype=np.float64),
        ms_levels=np.ones(3, dtype=np.int32),
        polarities=np.ones(3, dtype=np.int32),
        precursor_mzs=np.zeros(3, dtype=np.float64),
        precursor_charges=np.zeros(3, dtype=np.int32),
        base_peak_intensities=np.full(3, 100.0, dtype=np.float64))
    SpectralDataset.write_minimal(src, title="t", isa_investigation_id="",
                                  runs={"run_0001": run})
    p = tmp_path / "s.mzML"
    with SpectralDataset.open(src) as ds:
        w.write_dataset(ds, p, zlib_compression=False)
    return p


def test_mzml_reader_returns_draft(tmp_path):
    r = readers.MzMLReader()
    assert isinstance(r, Reader)
    ds = r.read([_write_mzml(tmp_path)], {})
    assert isinstance(ds, ImportedDataset)
    # mzML is delivered as a stream source (written through
    # SpectralStreamWriter), not a whole in-memory run.
    assert ds.spectral_streams and "run_0001" in ds.spectral_streams


def test_mzml_reader_round_trips(tmp_path):
    out = tmp_path / "o.tio"
    readers.MzMLReader().read([_write_mzml(tmp_path)], {}).write(out)
    with SpectralDataset.open(out) as ds:
        assert ds.ms_runs


def test_all_reader_classes_conform():
    # every class exposed for the registry must satisfy the Reader protocol
    for name in ("MzMLReader", "MzTabReader", "NmrMLReader", "ThermoRawReader",
                 "WatersMassLynxReader", "ImzMLReader", "BrukerReader",
                 "JcampDxReader", "BamReader", "SamReader", "CramReader"):
        cls = getattr(readers, name)
        assert isinstance(cls(), Reader), name
