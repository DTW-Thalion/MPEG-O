"""M73 parity: RamanSpectrum, IRSpectrum, RamanImage, IRImage + JCAMP-DX."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o import (
    AxisDescriptor,
    IRImage,
    IRMode,
    IRSpectrum,
    RamanImage,
    RamanSpectrum,
    SignalArray,
)
from mpeg_o.exporters.jcamp_dx import write_ir_spectrum, write_raman_spectrum
from mpeg_o.importers.jcamp_dx import read_spectrum


# --- helpers --------------------------------------------------------------


def _raman_fixture() -> RamanSpectrum:
    wn = np.linspace(100.0, 3500.0, 1024)
    intensity = np.abs(np.sin(wn / 137.0)) * 1e3
    return RamanSpectrum(
        signal_arrays={
            "wavenumber": SignalArray.from_numpy(
                wn, axis=AxisDescriptor("wavenumber", "1/cm")
            ),
            "intensity": SignalArray.from_numpy(
                intensity, axis=AxisDescriptor("intensity", "")
            ),
        },
        excitation_wavelength_nm=785.0,
        laser_power_mw=12.5,
        integration_time_sec=0.5,
    )


def _ir_fixture(mode: IRMode = IRMode.ABSORBANCE) -> IRSpectrum:
    wn = np.linspace(400.0, 4000.0, 2048)
    intensity = np.exp(-((wn - 1700.0) / 250.0) ** 2)
    return IRSpectrum(
        signal_arrays={
            "wavenumber": SignalArray.from_numpy(
                wn, axis=AxisDescriptor("wavenumber", "1/cm")
            ),
            "intensity": SignalArray.from_numpy(
                intensity, axis=AxisDescriptor("intensity", "")
            ),
        },
        mode=mode,
        resolution_cm_inv=4.0,
        number_of_scans=64,
    )


# --- spectrum construction -----------------------------------------------


def test_raman_spectrum_constructs() -> None:
    s = _raman_fixture()
    assert isinstance(s, RamanSpectrum)
    assert len(s.wavenumber_array) == 1024
    assert s.excitation_wavelength_nm == 785.0
    assert s.laser_power_mw == 12.5
    assert s.integration_time_sec == 0.5
    assert len(s) == 1024


def test_ir_spectrum_constructs_absorbance() -> None:
    s = _ir_fixture(IRMode.ABSORBANCE)
    assert s.mode is IRMode.ABSORBANCE
    assert s.resolution_cm_inv == 4.0
    assert s.number_of_scans == 64
    assert len(s) == 2048


def test_ir_spectrum_constructs_transmittance() -> None:
    s = _ir_fixture(IRMode.TRANSMITTANCE)
    assert s.mode is IRMode.TRANSMITTANCE


# --- JCAMP-DX round-trip --------------------------------------------------


def test_raman_jcamp_round_trip(tmp_path: Path) -> None:
    original = _raman_fixture()
    p = tmp_path / "raman.jdx"
    write_raman_spectrum(original, p, title="test Raman")
    decoded = read_spectrum(p)
    assert isinstance(decoded, RamanSpectrum)
    assert len(decoded.wavenumber_array) == 1024
    assert decoded.excitation_wavelength_nm == pytest.approx(785.0)
    assert decoded.laser_power_mw == pytest.approx(12.5)
    assert decoded.integration_time_sec == pytest.approx(0.5)
    np.testing.assert_allclose(
        decoded.wavenumber_array.data,
        original.wavenumber_array.data,
        rtol=1e-9,
        atol=1e-12,
    )
    np.testing.assert_allclose(
        decoded.intensity_array.data,
        original.intensity_array.data,
        rtol=1e-9,
        atol=1e-12,
    )


def test_ir_jcamp_round_trip_absorbance(tmp_path: Path) -> None:
    original = _ir_fixture(IRMode.ABSORBANCE)
    p = tmp_path / "ir_abs.jdx"
    write_ir_spectrum(original, p, title="test IR abs")
    decoded = read_spectrum(p)
    assert isinstance(decoded, IRSpectrum)
    assert decoded.mode is IRMode.ABSORBANCE
    assert decoded.resolution_cm_inv == pytest.approx(4.0)
    assert decoded.number_of_scans == 64
    assert len(decoded.wavenumber_array) == 2048
    np.testing.assert_allclose(
        decoded.intensity_array.data,
        original.intensity_array.data,
        rtol=1e-9,
        atol=1e-12,
    )


def test_ir_jcamp_round_trip_transmittance(tmp_path: Path) -> None:
    original = _ir_fixture(IRMode.TRANSMITTANCE)
    p = tmp_path / "ir_tr.jdx"
    write_ir_spectrum(original, p, title="test IR tr")
    decoded = read_spectrum(p)
    assert isinstance(decoded, IRSpectrum)
    assert decoded.mode is IRMode.TRANSMITTANCE


def test_jcamp_unknown_data_type_raises(tmp_path: Path) -> None:
    p = tmp_path / "bogus.jdx"
    p.write_text(
        "##TITLE=bogus\n##JCAMP-DX=5.01\n"
        "##DATA TYPE=MASS SPECTRUM\n"
        "##XYDATA=(X++(Y..Y))\n"
        "1.0 2.0\n"
        "##END=\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="unsupported DATA TYPE"):
        read_spectrum(p)


def test_jcamp_empty_xydata_raises(tmp_path: Path) -> None:
    p = tmp_path / "empty.jdx"
    p.write_text(
        "##TITLE=empty\n##JCAMP-DX=5.01\n"
        "##DATA TYPE=RAMAN SPECTRUM\n"
        "##XYDATA=(X++(Y..Y))\n"
        "##END=\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="empty or mismatched"):
        read_spectrum(p)


# --- imaging cube validation ---------------------------------------------


def test_raman_image_constructs_and_validates() -> None:
    h, w, sp = 16, 16, 32
    cube = np.arange(h * w * sp, dtype=np.float64).reshape(h, w, sp)
    wn = np.linspace(100.0, 3000.0, sp)
    img = RamanImage(
        width=w,
        height=h,
        spectral_points=sp,
        intensity=cube,
        wavenumbers=wn,
        pixel_size_x=0.5,
        pixel_size_y=0.5,
        scan_pattern="raster",
        tile_size=8,
        excitation_wavelength_nm=532.0,
        laser_power_mw=5.0,
        title="Raman map",
    )
    assert img.intensity.shape == (h, w, sp)
    assert img.wavenumbers.shape == (sp,)
    assert img.excitation_wavelength_nm == 532.0


def test_raman_image_rejects_shape_mismatch() -> None:
    with pytest.raises(ValueError, match="intensity shape"):
        RamanImage(
            width=8,
            height=8,
            spectral_points=16,
            intensity=np.zeros((8, 8, 32)),
            wavenumbers=np.zeros(16),
        )


def test_raman_image_rejects_wavenumbers_mismatch() -> None:
    with pytest.raises(ValueError, match="wavenumbers"):
        RamanImage(
            width=4,
            height=4,
            spectral_points=16,
            intensity=np.zeros((4, 4, 16)),
            wavenumbers=np.zeros(8),
        )


def test_ir_image_constructs_and_validates() -> None:
    h, w, sp = 8, 8, 64
    cube = np.ones((h, w, sp), dtype=np.float64) * 0.25
    wn = np.linspace(400.0, 4000.0, sp)
    img = IRImage(
        width=w,
        height=h,
        spectral_points=sp,
        intensity=cube,
        wavenumbers=wn,
        mode=IRMode.ABSORBANCE,
        resolution_cm_inv=8.0,
        scan_pattern="raster",
    )
    assert img.mode is IRMode.ABSORBANCE
    assert img.resolution_cm_inv == 8.0
    assert img.intensity.shape == (h, w, sp)


def test_ir_image_rejects_shape_mismatch() -> None:
    with pytest.raises(ValueError, match="intensity shape"):
        IRImage(
            width=4,
            height=4,
            spectral_points=16,
            intensity=np.zeros((4, 4, 32)),
            wavenumbers=np.zeros(16),
        )
