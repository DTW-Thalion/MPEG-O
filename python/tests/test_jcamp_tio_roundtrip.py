"""JCAMP-DX <-> .tio round-trip for the vibrational spectrum types.

Closes parity-audit v1.0 §3.1: AcquisitionRun now materializes
IR / Raman / UV-Vis spectra (not only MassSpectrum / NMRSpectrum), and
the encode/export registries bridge the JCAMP-DX codecs to a `.tio`. The
per-class metadata (IR mode/resolution/scans, Raman excitation/power/
integration, UV-Vis path-length/solvent) is persisted as run-group
attributes and recovered on materialization.
"""
from __future__ import annotations

import numpy as np
import pytest

from ttio import SpectralDataset
from ttio.enums import IRMode
from ttio.exporters import registry as ereg
from ttio.importers import registry as ireg
from ttio.importers import jcamp_dx as jcamp_read
from ttio.ir_spectrum import IRSpectrum
from ttio.raman_spectrum import RamanSpectrum
from ttio.signal_array import SignalArray
from ttio.uv_vis_spectrum import UVVisSpectrum


def _sa(arr) -> SignalArray:
    return SignalArray.from_numpy(np.asarray(arr, dtype=np.float64))


def _materialized(tio_path):
    with SpectralDataset.open(str(tio_path)) as ds:
        run = next(iter(ds.ms_runs.values()))
        spectra = run.spectra()
        assert spectra, "run materialized no spectra"
        return spectra[0]


def test_ir_jcamp_tio_round_trip(tmp_path):
    x = np.linspace(400.0, 4000.0, 24)
    y = np.abs(np.sin(x / 500.0)) + 0.1
    ir = IRSpectrum(
        signal_arrays={"wavenumber": _sa(x), "intensity": _sa(y)},
        mode=IRMode.ABSORBANCE, resolution_cm_inv=4.0, number_of_scans=32)

    from ttio.exporters.jcamp_dx import write_ir_spectrum
    src = tmp_path / "ir.jdx"
    write_ir_spectrum(ir, str(src))

    tio = tmp_path / "ir.tio"
    ireg.encode("jcamp-dx", [str(src)], str(tio))

    s = _materialized(tio)
    assert isinstance(s, IRSpectrum)
    assert s.mode == IRMode.ABSORBANCE
    assert s.resolution_cm_inv == 4.0
    assert s.number_of_scans == 32
    np.testing.assert_allclose(s.wavenumber_array.data, x)
    np.testing.assert_allclose(s.intensity_array.data, y)

    out = tmp_path / "ir_out.jdx"
    ereg.export("jcamp-dx", str(tio), None, str(out))
    rt = jcamp_read.read_spectrum(out)
    assert isinstance(rt, IRSpectrum)
    assert rt.mode == IRMode.ABSORBANCE
    assert rt.resolution_cm_inv == 4.0
    assert rt.number_of_scans == 32
    np.testing.assert_allclose(rt.wavenumber_array.data, x, rtol=1e-6)
    np.testing.assert_allclose(rt.intensity_array.data, y, rtol=1e-6)


def test_raman_jcamp_tio_round_trip(tmp_path):
    x = np.linspace(200.0, 3200.0, 24)
    y = np.abs(np.sin(x / 400.0)) + 0.05
    rm = RamanSpectrum(
        signal_arrays={"wavenumber": _sa(x), "intensity": _sa(y)},
        excitation_wavelength_nm=785.0, laser_power_mw=10.0,
        integration_time_sec=2.5)

    from ttio.exporters.jcamp_dx import write_raman_spectrum
    src = tmp_path / "rm.jdx"
    write_raman_spectrum(rm, str(src))

    tio = tmp_path / "rm.tio"
    ireg.encode("jcamp-dx", [str(src)], str(tio))

    s = _materialized(tio)
    assert isinstance(s, RamanSpectrum)
    assert s.excitation_wavelength_nm == 785.0
    assert s.laser_power_mw == 10.0
    assert s.integration_time_sec == 2.5
    np.testing.assert_allclose(s.wavenumber_array.data, x)
    np.testing.assert_allclose(s.intensity_array.data, y)

    out = tmp_path / "rm_out.jdx"
    ereg.export("jcamp-dx", str(tio), None, str(out))
    rt = jcamp_read.read_spectrum(out)
    assert isinstance(rt, RamanSpectrum)
    assert rt.excitation_wavelength_nm == 785.0
    assert rt.laser_power_mw == 10.0
    assert rt.integration_time_sec == 2.5


def test_uvvis_jcamp_tio_round_trip(tmp_path):
    wl = np.linspace(200.0, 800.0, 24)
    ab = np.abs(np.cos(wl / 100.0))
    uv = UVVisSpectrum(
        signal_arrays={"wavelength": _sa(wl), "absorbance": _sa(ab)},
        path_length_cm=1.0, solvent="methanol")

    from ttio.exporters.jcamp_dx import write_uv_vis_spectrum
    src = tmp_path / "uv.jdx"
    write_uv_vis_spectrum(uv, str(src))

    tio = tmp_path / "uv.tio"
    ireg.encode("jcamp-dx", [str(src)], str(tio))

    s = _materialized(tio)
    assert isinstance(s, UVVisSpectrum)
    assert s.path_length_cm == 1.0
    assert s.solvent == "methanol"
    np.testing.assert_allclose(s.wavelength_array.data, wl)
    np.testing.assert_allclose(s.absorbance_array.data, ab)

    out = tmp_path / "uv_out.jdx"
    ereg.export("jcamp-dx", str(tio), None, str(out))
    rt = jcamp_read.read_spectrum(out)
    assert isinstance(rt, UVVisSpectrum)
    assert rt.path_length_cm == 1.0
    assert rt.solvent == "methanol"
    np.testing.assert_allclose(rt.wavelength_array.data, wl, rtol=1e-6)


def test_ms_run_is_unaffected_by_new_attrs(tmp_path):
    """A plaintext MS .tio still materializes a MassSpectrum (the new
    vibrational run attributes are absent, so defaults apply)."""
    from ttio import WrittenRun
    from ttio.enums import AcquisitionMode
    from ttio.mass_spectrum import MassSpectrum
    src = tmp_path / "ms.tio"
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": np.linspace(100.0, 110.0, 6),
                      "intensity": np.linspace(1.0, 60.0, 6)},
        offsets=np.array([0], dtype=np.uint64),
        lengths=np.array([6], dtype=np.uint32),
        retention_times=np.array([0.0]),
        ms_levels=np.ones(1, dtype=np.int32),
        polarities=np.ones(1, dtype=np.int32),
        precursor_mzs=np.zeros(1),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=np.array([60.0]))
    SpectralDataset.write_minimal(
        str(src), title="ms", isa_investigation_id="TTIO:ms",
        runs={"run_0001": run})
    s = _materialized(src)
    assert isinstance(s, MassSpectrum)
