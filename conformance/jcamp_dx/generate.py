"""Regenerate the M76 JCAMP-DX compressed-writer golden fixtures.

Run from the ``python/`` directory (so the editable install is on
``sys.path``):

    python ../conformance/jcamp_dx/generate.py

Writes three golden ``.jdx`` files next to this script — one each
for PAC, SQZ, and DIF encoding — from a single deterministic
UV-Vis fixture. Java and Objective-C conformance tests read the
same bytes and compare against their own writer output.

The canonical input is documented in ``README.md`` (25-point
symmetric triangle absorbance over 200–440 nm).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from mpeg_o import AxisDescriptor, SignalArray, UVVisSpectrum
from mpeg_o.exporters.jcamp_dx import write_uv_vis_spectrum


def _fixture() -> UVVisSpectrum:
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


def main() -> int:
    here = Path(__file__).parent
    spec = _fixture()
    for mode in ("pac", "sqz", "dif"):
        dst = here / f"uvvis_ramp25_{mode}.jdx"
        write_uv_vis_spectrum(spec, dst, title="m76 ramp-25", encoding=mode)
        print(f"wrote {dst.relative_to(here.parent.parent)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
