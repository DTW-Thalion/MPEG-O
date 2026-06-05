"""P3.8: SpectrumKind enum maps to/from the persisted spectrum_class strings."""
from ttio.enums import SpectrumKind


def test_known_strings_round_trip():
    for s in ["TTIOMassSpectrum", "TTIONMRSpectrum", "TTIOIRSpectrum",
              "TTIORamanSpectrum", "TTIOUVVisSpectrum",
              "TTIOFreeInductionDecay", "TTIOMSImagePixel"]:
        k = SpectrumKind.from_persisted(s)
        assert k is not SpectrumKind.UNKNOWN
        assert k.persisted == s


def test_absent_defaults_to_mass():
    assert SpectrumKind.from_persisted(None) is SpectrumKind.MASS
    assert SpectrumKind.from_persisted("") is SpectrumKind.MASS


def test_unknown_is_unknown():
    assert SpectrumKind.from_persisted("TTIOFutureSpectrum") is SpectrumKind.UNKNOWN


# --- dispatch equivalence + byte-exact round-trip -------------------------

import numpy as np
import pytest

pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.enums import AcquisitionMode, Polarity
from ttio.ir_spectrum import IRSpectrum
from ttio.mass_spectrum import MassSpectrum
from ttio.nmr_spectrum import NMRSpectrum
from ttio.raman_spectrum import RamanSpectrum
from ttio.spectral_dataset import WrittenRun
from ttio.uv_vis_spectrum import UVVisSpectrum


def _written_run(spectrum_class: str) -> WrittenRun:
    """A minimal one-spectrum run carrying the given ``spectrum_class``.

    Vibrational metadata is supplied for IR/Raman/UVVis so the
    materialized subclass reconstructs cleanly; absent attributes fall
    back to the dataclass defaults (matching MS/NMR files).
    """
    n_pts = 4
    ch0 = np.linspace(100.0, 200.0, n_pts).astype(np.float64)
    intensity = (np.arange(n_pts, dtype=np.float64) + 1) * 1000.0
    kwargs = dict(
        spectrum_class=spectrum_class,
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": ch0, "intensity": intensity},
        offsets=np.zeros(1, dtype=np.uint64),
        lengths=np.full(1, n_pts, dtype=np.uint32),
        retention_times=np.zeros(1),
        ms_levels=np.ones(1, dtype=np.int32),
        polarities=np.full(1, int(Polarity.POSITIVE), dtype=np.int32),
        precursor_mzs=np.zeros(1),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=intensity[None, :].max(axis=1),
    )
    if spectrum_class == "TTIOIRSpectrum":
        kwargs.update(ir_mode=1, ir_resolution_cm_inv=4.0, ir_number_of_scans=64)
    elif spectrum_class == "TTIORamanSpectrum":
        kwargs.update(raman_excitation_wavelength_nm=785.0,
                      raman_laser_power_mw=12.5, raman_integration_time_sec=0.5)
    elif spectrum_class == "TTIOUVVisSpectrum":
        kwargs.update(uvvis_path_length_cm=1.0, solvent="water")
    return WrittenRun(**kwargs)


def _write_and_open_run(tmp_path, spectrum_class: str):
    path = tmp_path / "f.tio"
    SpectralDataset.write_minimal(
        path,
        title="p3.8 fixture",
        isa_investigation_id="ISA-P38",
        runs={"run_0001": _written_run(spectrum_class)},
    )
    return path


@pytest.mark.parametrize("spectrum_class,kind,cls", [
    ("TTIOMassSpectrum", SpectrumKind.MASS, MassSpectrum),
    ("TTIONMRSpectrum", SpectrumKind.NMR, NMRSpectrum),
    ("TTIOIRSpectrum", SpectrumKind.IR, IRSpectrum),
    ("TTIORamanSpectrum", SpectrumKind.RAMAN, RamanSpectrum),
    ("TTIOUVVisSpectrum", SpectrumKind.UVVIS, UVVisSpectrum),
])
def test_dispatch_materializes_expected_class(tmp_path, spectrum_class, kind, cls):
    path = _write_and_open_run(tmp_path, spectrum_class)
    with SpectralDataset.open(path) as ds:
        run = ds.ms_runs["run_0001"]
        assert run.kind is kind
        spec = run[0]
        assert isinstance(spec, cls)


def test_unknown_spectrum_class_round_trips_byte_exact(tmp_path):
    """An unrecognized spectrum_class is written verbatim, survives a
    round-trip unchanged, and dispatches to MassSpectrum (UNKNOWN default).
    """
    path = _write_and_open_run(tmp_path, "TTIOFutureSpectrum")
    with SpectralDataset.open(path) as ds:
        run = ds.ms_runs["run_0001"]
        assert run.spectrum_class == "TTIOFutureSpectrum"
        assert run.kind is SpectrumKind.UNKNOWN
        assert isinstance(run[0], MassSpectrum)
