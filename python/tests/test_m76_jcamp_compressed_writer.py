"""M76 — JCAMP-DX compressed writer (PAC / SQZ / DIF).

Covers the Python half of the cross-language byte-parity gate:

1. ``choose_yfactor`` normalises Y arrays to ~7 significant-digit
   integers with a deterministic power-of-ten scale.
2. Primitive encoders (``_encode_sqz``, ``_encode_dif``,
   ``_encode_pac_y``) mirror the decoder tables in
   :mod:`mpeg_o.importers._jcamp_decode` exactly.
3. End-to-end ``write_{raman,ir,uv_vis}_spectrum`` round-trip via the
   existing reader for all three compressed modes.
4. Opt-in: the default encoding stays AFFN; passing ``encoding="…"``
   is the only way to engage the compressed path.
5. Input validation: non-uniform X rejected for compressed modes;
   unknown encodings rejected up front.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o import AxisDescriptor, SignalArray, UVVisSpectrum
from mpeg_o.enums import IRMode
from mpeg_o.exporters._jcamp_encode import (
    VALUES_PER_LINE,
    choose_yfactor,
    encode_xydata,
    _encode_dif,
    _encode_pac_y,
    _encode_sqz,
)
from mpeg_o.exporters.jcamp_dx import (
    write_ir_spectrum,
    write_raman_spectrum,
    write_uv_vis_spectrum,
)
from mpeg_o.importers._jcamp_decode import decode_xydata
from mpeg_o.importers.jcamp_dx import read_spectrum
from mpeg_o.ir_spectrum import IRSpectrum
from mpeg_o.raman_spectrum import RamanSpectrum


# --- SQZ primitives ------------------------------------------------------


def test_sqz_zero() -> None:
    assert _encode_sqz(0) == "@"


def test_sqz_positive_single_digit() -> None:
    assert _encode_sqz(1) == "A"
    assert _encode_sqz(9) == "I"


def test_sqz_positive_multi_digit() -> None:
    assert _encode_sqz(123) == "A23"
    assert _encode_sqz(9999) == "I999"


def test_sqz_negative_single_digit() -> None:
    assert _encode_sqz(-1) == "a"
    assert _encode_sqz(-9) == "i"


def test_sqz_negative_multi_digit() -> None:
    assert _encode_sqz(-123) == "a23"


# --- DIF primitives ------------------------------------------------------


def test_dif_zero_delta() -> None:
    assert _encode_dif(0) == "%"


def test_dif_positive() -> None:
    # DIF table: % J K L M N O P Q R = 0..9
    assert _encode_dif(1) == "J"
    assert _encode_dif(9) == "R"
    assert _encode_dif(42) == "M2"  # leading digit 4 -> M


def test_dif_negative() -> None:
    assert _encode_dif(-1) == "j"
    assert _encode_dif(-53) == "n3"  # leading digit 5 -> n


# --- PAC primitives ------------------------------------------------------


def test_pac_zero() -> None:
    assert _encode_pac_y(0) == "+0"


def test_pac_positive() -> None:
    assert _encode_pac_y(42) == "+42"


def test_pac_negative() -> None:
    assert _encode_pac_y(-42) == "-42"


# --- YFACTOR choice ------------------------------------------------------


def test_yfactor_scales_to_seven_digits() -> None:
    # max |y| = 100 → ceil(log10) = 2 → yfactor = 10^(2-7) = 1e-5
    y = np.array([1.2345, 100.0, -50.0], dtype=np.float64)
    assert choose_yfactor(y) == pytest.approx(1e-5)


def test_yfactor_for_zero_array() -> None:
    assert choose_yfactor(np.zeros(5)) == 1.0


def test_yfactor_for_empty_array() -> None:
    assert choose_yfactor(np.array([], dtype=np.float64)) == 1.0


def test_yfactor_roundtrip_precision() -> None:
    # 7-digit precision relative to max_abs — single-YFACTOR scaling
    # preserves 1e-7 absolute error across the spectrum, which is
    # 1e-6 relative only for values near max_abs. Values many orders
    # of magnitude below max_abs get quantised aggressively (the
    # classic single-scale trade-off of JCAMP-DX compressed LDRs).
    y = np.array([123.4567, 50.12345, 99.99], dtype=np.float64)
    yf = choose_yfactor(y)
    recon = np.round(y / yf) * yf
    np.testing.assert_allclose(recon, y, rtol=1e-6)


# --- Full encoder: body layout --------------------------------------------


def test_encode_sqz_one_line_ramp() -> None:
    y = np.arange(1, 6, dtype=np.float64)  # [1, 2, 3, 4, 5]
    body = encode_xydata(
        y, firstx=100.0, deltax=1.0, yfactor=1.0, mode="sqz",
    )
    assert body == "100 A B C D E\n"


def test_encode_dif_one_line_ramp() -> None:
    y = np.arange(1, 6, dtype=np.float64)
    body = encode_xydata(
        y, firstx=100.0, deltax=1.0, yfactor=1.0, mode="dif",
    )
    # Expect: A (SQZ 1) then four DIFs of +1 each = J J J J
    assert body == "100 A J J J J\n"


def test_encode_pac_one_line_ramp() -> None:
    y = np.arange(1, 6, dtype=np.float64)
    body = encode_xydata(
        y, firstx=100.0, deltax=1.0, yfactor=1.0, mode="pac",
    )
    assert body == "100 +1+2+3+4+5\n"


def test_encode_sqz_line_break_at_ten_values() -> None:
    # 12 values → two lines, 10 + 2. Line 2 starts with an explicit
    # SQZ Y-check of line 1's last value (the decoder drops it).
    y = np.arange(1, 13, dtype=np.float64)
    body = encode_xydata(
        y, firstx=100.0, deltax=1.0, yfactor=1.0, mode="sqz",
    )
    assert body.count("\n") == 2
    first, second, _ = body.split("\n")
    assert first.split()[0] == "100"
    assert second.split()[0] == "110"
    # Line 1: anchor + 10 values. Line 2: anchor + Y-check + 2 values.
    assert len(first.split()) == 1 + VALUES_PER_LINE
    assert len(second.split()) == 1 + 1 + 2
    assert second.split()[1] == "A0"  # Y-check = SQZ(10)


def test_encode_dif_y_check_on_subsequent_line() -> None:
    # Line 2 must start with SQZ of line 1's last value for chain verify.
    y = np.arange(1, 13, dtype=np.float64)
    body = encode_xydata(
        y, firstx=100.0, deltax=1.0, yfactor=1.0, mode="dif",
    )
    lines = body.rstrip("\n").split("\n")
    assert len(lines) == 2
    second_tokens = lines[1].split()
    # second token is SQZ(10) = "A0" (leading digit 1 -> A, then "0");
    # third token is DIF(11-10)=+1 = "J".
    assert second_tokens[1] == "A0"
    assert second_tokens[2] == "J"


def test_encode_rejects_unknown_mode() -> None:
    with pytest.raises(ValueError, match="unknown"):
        encode_xydata(
            np.array([1.0], dtype=np.float64),
            firstx=0.0, deltax=1.0, yfactor=1.0, mode="nope",
        )


# --- Decoder round-trip --------------------------------------------------


@pytest.mark.parametrize("mode", ["pac", "sqz", "dif"])
def test_encoder_decoder_roundtrip(mode: str) -> None:
    # Integer ramp, 12 values → two compressed lines.
    y = np.arange(1, 13, dtype=np.float64)
    body = encode_xydata(
        y, firstx=100.0, deltax=0.5, yfactor=1.0, mode=mode,
    )
    xs, ys = decode_xydata(
        body.splitlines(), firstx=100.0, deltax=0.5, yfactor=1.0,
    )
    assert ys == list(y)
    np.testing.assert_allclose(xs, [100.0 + 0.5 * i for i in range(12)])


# --- Spectrum-level round-trip ------------------------------------------


def _uvvis_fixture() -> UVVisSpectrum:
    wl = np.linspace(200.0, 800.0, 601)
    absorb = np.exp(-((wl - 450.0) / 40.0) ** 2)
    return UVVisSpectrum(
        signal_arrays={
            UVVisSpectrum.WAVELENGTH: SignalArray.from_numpy(
                wl, axis=AxisDescriptor("wavelength", "nm")
            ),
            UVVisSpectrum.ABSORBANCE: SignalArray.from_numpy(
                absorb, axis=AxisDescriptor("absorbance", "")
            ),
        },
        path_length_cm=1.0,
        solvent="methanol",
    )


@pytest.mark.parametrize("mode", ["pac", "sqz", "dif"])
def test_uvvis_compressed_roundtrip(tmp_path: Path, mode: str) -> None:
    original = _uvvis_fixture()
    p = tmp_path / f"uvvis_{mode}.jdx"
    write_uv_vis_spectrum(original, p, title=f"m76 {mode}", encoding=mode)
    decoded = read_spectrum(p)
    assert isinstance(decoded, UVVisSpectrum)
    assert decoded.path_length_cm == pytest.approx(1.0)
    assert decoded.solvent == "methanol"
    # Compressed forms carry ~7 sig-digit precision relative to max|y|.
    # With max|y| = 1.0 this becomes atol ≈ 5e-8; we use 1e-6 to cover
    # the full Gaussian-tail dynamic range of this fixture.
    np.testing.assert_allclose(
        decoded.wavelength_array.data,
        original.wavelength_array.data,
        rtol=1e-9, atol=1e-9,
    )
    np.testing.assert_allclose(
        decoded.absorbance_array.data,
        original.absorbance_array.data,
        atol=1e-6,
    )


@pytest.mark.parametrize("mode", ["pac", "sqz", "dif"])
def test_raman_compressed_roundtrip(tmp_path: Path, mode: str) -> None:
    wn = np.linspace(100.0, 3000.0, 2901)
    intensity = np.sin(wn / 100.0) + 2.0
    spec = RamanSpectrum(
        signal_arrays={
            RamanSpectrum.WAVENUMBER: SignalArray.from_numpy(
                wn, axis=AxisDescriptor("wavenumber", "1/cm")
            ),
            RamanSpectrum.INTENSITY: SignalArray.from_numpy(
                intensity, axis=AxisDescriptor("intensity", "")
            ),
        },
        excitation_wavelength_nm=785.0,
        laser_power_mw=50.0,
        integration_time_sec=1.5,
    )
    p = tmp_path / f"raman_{mode}.jdx"
    write_raman_spectrum(spec, p, title=f"m76 {mode}", encoding=mode)
    decoded = read_spectrum(p)
    assert isinstance(decoded, RamanSpectrum)
    np.testing.assert_allclose(
        decoded.intensity_array.data,
        intensity, rtol=1e-6, atol=1e-6,
    )


@pytest.mark.parametrize("mode", ["pac", "sqz", "dif"])
def test_ir_compressed_roundtrip(tmp_path: Path, mode: str) -> None:
    wn = np.linspace(400.0, 4000.0, 3601)
    absorbance = 0.5 * (1.0 + np.cos(wn / 500.0))
    spec = IRSpectrum(
        signal_arrays={
            IRSpectrum.WAVENUMBER: SignalArray.from_numpy(
                wn, axis=AxisDescriptor("wavenumber", "1/cm")
            ),
            IRSpectrum.INTENSITY: SignalArray.from_numpy(
                absorbance, axis=AxisDescriptor("absorbance", "")
            ),
        },
        mode=IRMode.ABSORBANCE,
        resolution_cm_inv=4.0,
        number_of_scans=32,
    )
    p = tmp_path / f"ir_{mode}.jdx"
    write_ir_spectrum(spec, p, title=f"m76 {mode}", encoding=mode)
    decoded = read_spectrum(p)
    assert isinstance(decoded, IRSpectrum)
    np.testing.assert_allclose(
        decoded.intensity_array.data,
        absorbance, rtol=1e-6, atol=1e-6,
    )


# --- Validation ---------------------------------------------------------


def test_default_encoding_is_affn(tmp_path: Path) -> None:
    # No encoding keyword → AFFN (one X/Y pair per line, no compression chars).
    original = _uvvis_fixture()
    p = tmp_path / "default.jdx"
    write_uv_vis_spectrum(original, p, title="default")
    text = p.read_text(encoding="utf-8")
    # AFFN body has no SQZ/DIF/DUP characters on data lines.
    data_lines = [
        ln for ln in text.splitlines()
        if ln and not ln.startswith("##")
    ]
    assert data_lines, "AFFN writer should still produce data lines"
    for ln in data_lines:
        for ch in "@%JK":  # sampled compression sentinels
            assert ch not in ln


def test_unknown_encoding_rejected(tmp_path: Path) -> None:
    original = _uvvis_fixture()
    with pytest.raises(ValueError, match="unknown JCAMP-DX encoding"):
        write_uv_vis_spectrum(
            original, tmp_path / "x.jdx", encoding="gzip",
        )


def test_non_uniform_x_rejected_for_compressed(tmp_path: Path) -> None:
    wl = np.array([200.0, 201.0, 203.0, 210.0], dtype=np.float64)  # non-uniform
    absorb = np.array([0.1, 0.2, 0.3, 0.4], dtype=np.float64)
    spec = UVVisSpectrum(
        signal_arrays={
            UVVisSpectrum.WAVELENGTH: SignalArray.from_numpy(
                wl, axis=AxisDescriptor("wavelength", "nm")
            ),
            UVVisSpectrum.ABSORBANCE: SignalArray.from_numpy(
                absorb, axis=AxisDescriptor("absorbance", "")
            ),
        },
        path_length_cm=1.0,
        solvent="water",
    )
    with pytest.raises(ValueError, match="equispaced"):
        write_uv_vis_spectrum(
            spec, tmp_path / "nonuniform.jdx", encoding="sqz",
        )


def test_non_uniform_x_accepted_for_affn(tmp_path: Path) -> None:
    # AFFN path handles arbitrary X spacing — regression guard.
    wl = np.array([200.0, 201.0, 203.0, 210.0], dtype=np.float64)
    absorb = np.array([0.1, 0.2, 0.3, 0.4], dtype=np.float64)
    spec = UVVisSpectrum(
        signal_arrays={
            UVVisSpectrum.WAVELENGTH: SignalArray.from_numpy(
                wl, axis=AxisDescriptor("wavelength", "nm")
            ),
            UVVisSpectrum.ABSORBANCE: SignalArray.from_numpy(
                absorb, axis=AxisDescriptor("absorbance", "")
            ),
        },
        path_length_cm=1.0,
        solvent="water",
    )
    p = tmp_path / "nonuniform.jdx"
    write_uv_vis_spectrum(spec, p)  # default affn
    decoded = read_spectrum(p)
    np.testing.assert_allclose(decoded.wavelength_array.data, wl)
