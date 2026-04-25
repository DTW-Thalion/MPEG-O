"""Tests for the spectrum / signal hierarchy value classes."""
from __future__ import annotations

import numpy as np
import pytest

from ttio import (
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
from ttio.enums import ChromatogramType


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
        signal_arrays={"mz": mz, "intensity": it},
        scan_time_seconds=12.34,
        ms_level=1,
        polarity=Polarity.POSITIVE,
        index_position=0,
    )
    np.testing.assert_array_equal(s.mz_array.data, mz.data)
    np.testing.assert_array_equal(s.intensity_array.data, it.data)
    assert len(s) == 3
    assert s.polarity is Polarity.POSITIVE
    assert s.has_signal_array("mz")
    assert not s.has_signal_array("chemical_shift")


def test_spectrum_missing_channel_raises() -> None:
    s = Spectrum()
    with pytest.raises(KeyError):
        s.signal_array("mz")


def test_nmr_spectrum_channels() -> None:
    cs = SignalArray.from_numpy(
        np.array([0.0, 1.0, 2.0]), axis=AxisDescriptor("chemical_shift", "ppm")
    )
    it = SignalArray.from_numpy(np.array([1.0, 2.0, 3.0]), axis=_int_axis())
    s = NMRSpectrum(signal_arrays={"chemical_shift": cs, "intensity": it}, nucleus_type="1H")
    np.testing.assert_array_equal(s.chemical_shift_array.data, cs.data)
    assert s.nucleus_type == "1H"


def test_nmr_2d_spectrum_shape_validation() -> None:
    from ttio.axis_descriptor import AxisDescriptor
    from ttio.value_range import ValueRange
    matrix = np.zeros((4, 8), dtype=np.float64)
    f1 = AxisDescriptor(name="1H", unit="ppm", value_range=ValueRange(0.0, 10.0))
    f2 = AxisDescriptor(name="13C", unit="ppm", value_range=ValueRange(0.0, 200.0))
    nmr2d = NMR2DSpectrum(intensity_matrix=matrix, f1_axis=f1, f2_axis=f2,
                          nucleus_f1="1H", nucleus_f2="13C")
    assert nmr2d.matrix_height == 4
    assert nmr2d.matrix_width == 8


def test_nmr_2d_spectrum_rejects_rank_1() -> None:
    with pytest.raises(ValueError):
        NMR2DSpectrum(intensity_matrix=np.zeros(10))


def test_nmr_2d_spectrum_rejects_rank_3() -> None:
    with pytest.raises(ValueError):
        NMR2DSpectrum(intensity_matrix=np.zeros((2, 3, 4)))


def test_fid() -> None:
    fid = FreeInductionDecay(
        data=np.zeros(16384, dtype=np.complex128),
        dwell_time_seconds=1e-4,
        scan_count=8,
        receiver_gain=50.0,
    )
    assert len(fid) == 16384


def test_fid_inherits_signal_array() -> None:
    fid = FreeInductionDecay(
        data=np.zeros(512, dtype=np.complex128),
        dwell_time_seconds=5e-5,
        scan_count=16,
        receiver_gain=100.0,
    )
    assert isinstance(fid, SignalArray)
    assert fid.dwell_time_seconds == 5e-5
    assert fid.scan_count == 16
    assert fid.receiver_gain == 100.0
    # Old fields gone:
    assert not hasattr(fid, "dwell_time_s")
    assert not hasattr(fid, "spectrometer_frequency_mhz")
    assert not hasattr(fid, "nucleus")


def test_chromatogram_validation() -> None:
    from ttio.signal_array import SignalArray

    rt = np.arange(10, dtype=np.float64)
    it = np.arange(10, dtype=np.float64) * 2
    c = Chromatogram(
        signal_arrays={"time": SignalArray(data=rt), "intensity": SignalArray(data=it)},
        axes=[],
        chromatogram_type=ChromatogramType.TIC,
    )
    assert len(c) == 10
    assert not hasattr(c, "retention_times")
    assert not hasattr(c, "intensities")
    assert not hasattr(c, "name")


def test_chromatogram_inherits_spectrum() -> None:
    from ttio.chromatogram import Chromatogram
    from ttio.spectrum import Spectrum
    from ttio.enums import ChromatogramType
    import numpy as np

    t = SignalArray(data=np.array([0.0, 1.0, 2.0]))
    i = SignalArray(data=np.array([100.0, 200.0, 300.0]))
    chrom = Chromatogram(
        signal_arrays={"time": t, "intensity": i},
        axes=[],
        chromatogram_type=ChromatogramType.TIC,
    )
    assert isinstance(chrom, Spectrum)
    assert isinstance(chrom.time_array, SignalArray)
    assert chrom.chromatogram_type is ChromatogramType.TIC
    assert not hasattr(chrom, "retention_times")
    assert not hasattr(chrom, "intensities")
    assert not hasattr(chrom, "name")
