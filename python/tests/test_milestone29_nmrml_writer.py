"""Milestone 29 — nmrML writer + Thermo RAW stub."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o.exporters.nmrml import spectrum_to_bytes, write_spectrum
from mpeg_o.nmr_spectrum import NMRSpectrum
from mpeg_o.signal_array import SignalArray
from mpeg_o.axis_descriptor import AxisDescriptor


def _make_spectrum() -> NMRSpectrum:
    cs = np.array([0.5, 1.5, 2.5, 3.5], dtype=np.float64)
    it = np.array([10.0, 20.0, 30.0, 20.0], dtype=np.float64)
    return NMRSpectrum(
        channels={
            "chemical_shift": SignalArray.from_numpy(cs, axis=AxisDescriptor(name="chemical_shift", unit="ppm")),
            "intensity": SignalArray.from_numpy(it, axis=AxisDescriptor(name="intensity", unit="counts")),
        },
        nucleus="1H",
        retention_time=0.0,
        ms_level=0,
        polarity=0,
        precursor_mz=0.0,
        precursor_charge=0,
        base_peak_intensity=30.0,
        index=0,
        run_name="",
    )


def test_nmrml_writer_produces_valid_xml() -> None:
    spec = _make_spectrum()
    blob = spectrum_to_bytes(spec, sweep_width_ppm=10.0)
    text = blob.decode("utf-8")
    assert "<nmrML" in text
    assert "NMR:1000001" in text
    assert "NMR:1000002" in text
    assert "NMR:1400014" in text
    assert "<spectrum1D>" in text
    assert "<xAxis>" in text
    assert "<yAxis>" in text


def test_nmrml_write_to_disk(tmp_path: Path) -> None:
    spec = _make_spectrum()
    out = tmp_path / "test.nmrML"
    write_spectrum(spec, out, sweep_width_ppm=10.0)
    assert out.is_file()
    assert out.stat().st_size > 100


def test_thermo_raw_stub_raises() -> None:
    from mpeg_o.importers.thermo_raw import read
    with pytest.raises(NotImplementedError, match="not yet implemented"):
        read("/tmp/fake.raw")
