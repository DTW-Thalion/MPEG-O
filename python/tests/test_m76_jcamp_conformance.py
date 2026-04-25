"""M76 — byte-parity conformance check for the JCAMP-DX compressed writer.

Each mode (PAC / SQZ / DIF) has a matching golden fixture under
``conformance/jcamp_dx/``. This test regenerates the same output
in-process and asserts byte-for-byte equality. Java and Objective-C
ship the analogous tests — together they form the M76 cross-language
byte-parity gate.

If this test starts failing, either:

1. The Python encoder changed (intentional) — regenerate the
   goldens via ``python conformance/jcamp_dx/generate.py`` **and**
   push through the Java + ObjC writers so all three re-align.
2. The Python encoder changed (unintentional) — revert.

Silently-updating the goldens defeats the whole purpose of the gate.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import AxisDescriptor, SignalArray, UVVisSpectrum
from ttio.exporters.jcamp_dx import write_uv_vis_spectrum


_CONFORMANCE = Path(__file__).resolve().parents[2] / "conformance" / "jcamp_dx"


def _ramp25_fixture() -> UVVisSpectrum:
    wl = np.linspace(200.0, 440.0, 25, dtype=np.float64)
    absorb = np.array([min(i, 24 - i) for i in range(25)], dtype=np.float64)
    return UVVisSpectrum(
        signal_arrays={
            UVVisSpectrum.WAVELENGTH: SignalArray.from_numpy(
                wl, axis=AxisDescriptor("wavelength", "nm"),
            ),
            UVVisSpectrum.ABSORBANCE: SignalArray.from_numpy(
                absorb, axis=AxisDescriptor("absorbance", ""),
            ),
        },
        path_length_cm=1.0,
        solvent="water",
    )


@pytest.mark.parametrize("mode", ["pac", "sqz", "dif"])
def test_python_writer_matches_golden(tmp_path: Path, mode: str) -> None:
    golden = _CONFORMANCE / f"uvvis_ramp25_{mode}.jdx"
    if not golden.is_file():
        pytest.skip(f"golden fixture missing: {golden}")
    out = tmp_path / f"gen_{mode}.jdx"
    write_uv_vis_spectrum(
        _ramp25_fixture(), out, title="m76 ramp-25", encoding=mode,
    )
    produced = out.read_bytes()
    expected = golden.read_bytes()
    assert produced == expected, (
        f"byte-parity drift on {mode.upper()} encoder.\n"
        f"--- expected ({golden.name}) ---\n{expected.decode(errors='replace')}"
        f"--- produced ---\n{produced.decode(errors='replace')}"
    )
