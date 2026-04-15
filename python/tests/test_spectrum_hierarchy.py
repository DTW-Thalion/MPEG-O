"""Tests for the spectrum / signal hierarchy value classes."""
from __future__ import annotations

import numpy as np
import pytest

from mpeg_o import (
    AxisDescriptor,
    Chromatogram,
    EncodingSpec,
    MassSpectrum,
    NMR2DSpectrum,
    NMRSpectrum,
    Polarity,
    SignalArray,
    Spectrum,
    FreeInductionDecay,
)
from mpeg_o.enums import ChromatogramType


def _mz_axis() -> AxisDescriptor:
    return AxisDescriptor(name="mz", unit="m/z")


def _int_axis() -> AxisDescriptor:
    return AxisDescriptor(name="intensity", unit="counts")


def test_signal_array_from_numpy_round_trip() -> None:
    arr = np.linspace(100.0, 200.0, 10, dtype=np.float64)
    sig = SignalArray.from_numpy(arr, axis=_mz_axis())
    assert len(sig) == 10
    assert sig.axis.name == "mz"
    assert isinstance(sig.encoding, EncodingSpec)
    np.testing.assert_array_equal(sig.data, arr)


def test_signal_array_rejects_rank_mismatch() -> None:
    with pytest.raises(ValueError):
        SignalArray.from_numpy(np.zeros((3, 3)), axis=_mz_axis())


def test_mass_spectrum_channel_convenience() -> None:
    mz = SignalArray.from_numpy(np.array([100.0, 200.0, 300.0]), axis=_mz_axis())
    it = SignalArray.from_numpy(np.array([10.0, 50.0, 5.0]), axis=_int_axis())
    s = MassSpectrum(
        channels={"mz": mz, "intensity": it},
        retention_time=12.34,
        ms_level=1,
        polarity=Polarity.POSITIVE,
        base_peak_intensity=50.0,
        index=0,
        run_name="run_0001",
    )
    np.testing.assert_array_equal(s.mz_array.data, mz.data)
    np.testing.assert_array_equal(s.intensity_array.data, it.data)
    assert len(s) == 3
    assert s.polarity is Polarity.POSITIVE
    assert s.has_channel("mz")
    assert not s.has_channel("chemical_shift")


def test_spectrum_missing_channel_raises() -> None:
    s = Spectrum()
    with pytest.raises(KeyError):
        s.channel("mz")


def test_nmr_spectrum_channels() -> None:
    cs = SignalArray.from_numpy(
        np.array([0.0, 1.0, 2.0]), axis=AxisDescriptor("chemical_shift", "ppm")
    )
    it = SignalArray.from_numpy(np.array([1.0, 2.0, 3.0]), axis=_int_axis())
    s = NMRSpectrum(channels={"chemical_shift": cs, "intensity": it}, nucleus="1H")
    np.testing.assert_array_equal(s.chemical_shift_array.data, cs.data)
    assert s.nucleus == "1H"


def test_nmr_2d_spectrum_shape_validation() -> None:
    matrix = np.zeros((4, 8), dtype=np.float64)
    f1 = np.linspace(0.0, 10.0, 4)
    f2 = np.linspace(0.0, 10.0, 8)
    nmr2d = NMR2DSpectrum(matrix, f1, f2, nucleus_f1="1H", nucleus_f2="13C")
    assert nmr2d.matrix_height == 4
    assert nmr2d.matrix_width == 8


def test_nmr_2d_spectrum_rejects_wrong_scales() -> None:
    matrix = np.zeros((4, 8), dtype=np.float64)
    with pytest.raises(ValueError):
        NMR2DSpectrum(matrix, np.zeros(3), np.zeros(8))


def test_nmr_2d_spectrum_rejects_rank_1() -> None:
    with pytest.raises(ValueError):
        NMR2DSpectrum(np.zeros(10), np.zeros(10), np.zeros(10))


def test_fid() -> None:
    fid = FreeInductionDecay(
        data=np.zeros(16384, dtype=np.complex128),
        dwell_time_s=1e-4,
        spectrometer_frequency_mhz=600.13,
        nucleus="1H",
    )
    assert len(fid) == 16384


def test_chromatogram_validation() -> None:
    rt = np.arange(10, dtype=np.float64)
    it = np.arange(10, dtype=np.float64) * 2
    c = Chromatogram(rt, it, chromatogram_type=ChromatogramType.TIC, name="TIC")
    assert len(c) == 10
    with pytest.raises(ValueError):
        Chromatogram(rt, np.arange(9, dtype=np.float64))
