"""v0.11.1 parity: PAC/SQZ/DIF/DUP decoder + UVVisSpectrum round-trip."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import AxisDescriptor, SignalArray, UVVisSpectrum
from ttio.exporters.jcamp_dx import write_uv_vis_spectrum
from ttio.importers._jcamp_decode import decode_xydata, has_compression
from ttio.importers.jcamp_dx import read_spectrum


# --- compression primitives ----------------------------------------------


def test_has_compression_detects_sqz() -> None:
    assert has_compression("450.0A3000B250")


def test_has_compression_detects_dif() -> None:
    assert has_compression("450.0%J3K2")


def test_has_compression_detects_dup() -> None:
    assert has_compression("450.0@5S")


def test_has_compression_false_for_affn() -> None:
    assert not has_compression("450.0 12.5\n451.0 13.0\n")


def test_has_compression_false_for_scientific_notation() -> None:
    # 'e' / 'E' appear in scientific-notation AFFN; must not trigger.
    assert not has_compression("450.0 1.234e-05\n451.0 9.87E+03\n")


# --- SQZ decode ----------------------------------------------------------


def test_sqz_positive_single_digit() -> None:
    # A = +1, B = +2, C = +3
    xs, ys = decode_xydata(
        ["100 A B C"], firstx=100.0, deltax=1.0,
    )
    assert xs == [100.0, 101.0, 102.0]
    assert ys == [1.0, 2.0, 3.0]


def test_sqz_positive_multi_digit() -> None:
    # A23 = 123
    xs, ys = decode_xydata(
        ["100 A23"], firstx=100.0, deltax=1.0,
    )
    assert ys == [123.0]


def test_sqz_negative_single_digit() -> None:
    # a = -1, b = -2
    xs, ys = decode_xydata(
        ["100 a b"], firstx=100.0, deltax=1.0,
    )
    assert ys == [-1.0, -2.0]


def test_sqz_at_zero() -> None:
    # @ = 0
    xs, ys = decode_xydata(["100 @"], firstx=100.0, deltax=1.0)
    assert ys == [0.0]


# --- DIF decode ----------------------------------------------------------


def test_dif_cumulative() -> None:
    # Start with A (=1), then DIF J (=+1), K (=+2) → 1, 2, 4
    xs, ys = decode_xydata(
        ["100 A J K"], firstx=100.0, deltax=1.0,
    )
    assert ys == [1.0, 2.0, 4.0]


def test_dif_percent_zero_delta() -> None:
    # A (=1), % (=+0) → 1, 1
    xs, ys = decode_xydata(["100 A %"], firstx=100.0, deltax=1.0)
    assert ys == [1.0, 1.0]


def test_dif_negative_delta() -> None:
    # C (=3), j (=-1), k (=-2) → 3, 2, 0
    xs, ys = decode_xydata(
        ["100 C j k"], firstx=100.0, deltax=1.0,
    )
    assert ys == [3.0, 2.0, 0.0]


# --- DUP decode ----------------------------------------------------------


def test_dup_repeats_prior() -> None:
    # A (=1), S (=2) → emit A, then repeat A once more → 1, 1
    xs, ys = decode_xydata(["100 A S"], firstx=100.0, deltax=1.0)
    assert ys == [1.0, 1.0]


def test_dup_larger_count() -> None:
    # A (=1), U (=4) → 1, 1, 1, 1 (emit + 3 repeats = 4 total)
    xs, ys = decode_xydata(["100 A U"], firstx=100.0, deltax=1.0)
    assert ys == [1.0, 1.0, 1.0, 1.0]


# --- DIF Y-check drop ----------------------------------------------------


def test_dif_y_check_dropped() -> None:
    # Canonical DIF chain: last Y of line 1 repeated as leading SQZ
    # on line 2 for verification; decoder must drop it.
    xs, ys = decode_xydata(
        ["100 A J", "102 B"],  # line1: 1, 2; line2 starts with B=2 (check)
        firstx=100.0, deltax=1.0,
    )
    assert ys == [1.0, 2.0]


# --- XYDATA round-trip via an equivalent compressed fixture -------------


def test_compressed_xydata_round_trip_through_reader(tmp_path: Path) -> None:
    # Hand-encode a 5-point ramp {1,2,3,4,5} in SQZ form.
    # A=1 J=+1 J=+1 J=+1 J=+1 → 1 2 3 4 5.
    jdx = (
        "##TITLE=compressed\n"
        "##JCAMP-DX=5.01\n"
        "##DATA TYPE=INFRARED ABSORBANCE\n"
        "##XUNITS=1/CM\n"
        "##YUNITS=ABSORBANCE\n"
        "##FIRSTX=100\n"
        "##LASTX=104\n"
        "##NPOINTS=5\n"
        "##XFACTOR=1\n"
        "##YFACTOR=1\n"
        "##XYDATA=(X++(Y..Y))\n"
        "100 A J J J J\n"
        "##END=\n"
    )
    p = tmp_path / "compressed_ir.jdx"
    p.write_text(jdx, encoding="utf-8")
    decoded = read_spectrum(p)
    np.testing.assert_allclose(
        decoded.wavenumber_array.data,
        [100.0, 101.0, 102.0, 103.0, 104.0],
    )
    np.testing.assert_allclose(
        decoded.intensity_array.data,
        [1.0, 2.0, 3.0, 4.0, 5.0],
    )


def test_compressed_requires_firstx_lastx_npoints(tmp_path: Path) -> None:
    jdx = (
        "##TITLE=no_headers\n"
        "##JCAMP-DX=5.01\n"
        "##DATA TYPE=INFRARED ABSORBANCE\n"
        "##XYDATA=(X++(Y..Y))\n"
        "100 A J J J J\n"
        "##END=\n"
    )
    p = tmp_path / "bad.jdx"
    p.write_text(jdx, encoding="utf-8")
    with pytest.raises(ValueError, match="FIRSTX"):
        read_spectrum(p)


# --- UVVisSpectrum round-trip --------------------------------------------


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


def test_uvvis_spectrum_constructs() -> None:
    s = _uvvis_fixture()
    assert isinstance(s, UVVisSpectrum)
    assert len(s.wavelength_array) == 601
    assert s.path_length_cm == 1.0
    assert s.solvent == "methanol"


def test_uvvis_jcamp_round_trip(tmp_path: Path) -> None:
    original = _uvvis_fixture()
    p = tmp_path / "uvvis.jdx"
    write_uv_vis_spectrum(original, p, title="test UV-Vis")
    decoded = read_spectrum(p)
    assert isinstance(decoded, UVVisSpectrum)
    assert decoded.path_length_cm == pytest.approx(1.0)
    assert decoded.solvent == "methanol"
    np.testing.assert_allclose(
        decoded.wavelength_array.data,
        original.wavelength_array.data,
        rtol=1e-9, atol=1e-12,
    )
    np.testing.assert_allclose(
        decoded.absorbance_array.data,
        original.absorbance_array.data,
        rtol=1e-9, atol=1e-12,
    )


def test_uvvis_alternate_data_type_spellings(tmp_path: Path) -> None:
    for variant in ("UV/VIS SPECTRUM", "UV-VIS SPECTRUM", "UV/VISIBLE SPECTRUM"):
        jdx = (
            "##TITLE=variant\n"
            "##JCAMP-DX=5.01\n"
            f"##DATA TYPE={variant}\n"
            "##XUNITS=NANOMETERS\n"
            "##YUNITS=ABSORBANCE\n"
            "##XYDATA=(X++(Y..Y))\n"
            "200 0.1\n"
            "250 0.2\n"
            "##END=\n"
        )
        p = tmp_path / f"variant_{variant.replace('/', '_')}.jdx"
        p.write_text(jdx, encoding="utf-8")
        decoded = read_spectrum(p)
        assert isinstance(decoded, UVVisSpectrum)
