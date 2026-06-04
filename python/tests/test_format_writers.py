from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.exporters.base import Writer
from ttio.exporters import writers


def _ds(tmp_path: Path) -> Path:
    src = tmp_path / "s.tio"
    run = WrittenRun(
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
        base_peak_intensities=np.full(1, 60.0, dtype=np.float64))
    SpectralDataset.write_minimal(src, title="t", isa_investigation_id="",
                                  runs={"run_0001": run})
    return src


def test_mzml_writer(tmp_path):
    w = writers.MzMLWriter()
    assert isinstance(w, Writer)
    out = tmp_path / "o.mzML"
    with SpectralDataset.open(_ds(tmp_path)) as ds:
        w.write(ds, None, str(out), {})
    assert out.exists() and out.stat().st_size > 0


def test_all_writer_classes_conform():
    for name in ("MzMLWriter", "MzTabWriter", "IsaWriter", "NmrMLWriter",
                 "ImzMLWriter", "JcampDxWriter", "BamWriter", "CramWriter"):
        assert isinstance(getattr(writers, name)(), Writer), name
