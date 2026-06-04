from __future__ import annotations

import numpy as np

from ttio.importers.import_result import ImportResult, ImportedSpectrum
from ttio.importers.imported_dataset import ImportedDataset


def _result() -> ImportResult:
    r = ImportResult(title="x", isa_investigation_id="TTIO:x")
    r.ms_spectra.append(ImportedSpectrum(
        mz_or_chemical_shift=np.linspace(100.0, 105.0, 5),
        intensity=np.linspace(1.0, 50.0, 5), retention_time=0.5, ms_level=1))
    return r


def test_to_imported_dataset_carries_runs():
    ds = _result().to_imported_dataset()
    assert isinstance(ds, ImportedDataset)
    assert "run_0001" in ds.runs
    assert ds.title == "x"


def test_to_ttio_still_round_trips(tmp_path):
    from ttio import SpectralDataset
    out = tmp_path / "r.tio"
    _result().to_ttio(out)
    with SpectralDataset.open(out) as d:
        assert d.ms_runs
