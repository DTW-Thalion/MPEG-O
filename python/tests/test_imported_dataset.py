from __future__ import annotations

import numpy as np

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.importers.imported_dataset import ImportedDataset


def _run() -> WrittenRun:
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": np.linspace(100.0, 105.0, 6),
                      "intensity": np.linspace(1.0, 60.0, 6)},
        offsets=np.zeros(1, dtype=np.uint64),
        lengths=np.full(1, 6, dtype=np.uint32),
        retention_times=np.zeros(1, dtype=np.float64),
        ms_levels=np.ones(1, dtype=np.int32),
        polarities=np.ones(1, dtype=np.int32),
        precursor_mzs=np.zeros(1, dtype=np.float64),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=np.full(1, 60.0, dtype=np.float64),
    )


def test_write_round_trips(tmp_path):
    out = tmp_path / "d.tio"
    draft = ImportedDataset(title="t", isa_investigation_id="TTIO:t",
                            runs={"run_0001": _run()})
    returned = draft.write(out)
    assert returned == out
    with SpectralDataset.open(out) as ds:
        assert ds.ms_runs


def test_empty_genomic_runs_pass_none(tmp_path):
    out = tmp_path / "e.tio"
    ImportedDataset(title="g", isa_investigation_id="",
                    runs={"run_0001": _run()}).write(out)
    assert out.exists()
