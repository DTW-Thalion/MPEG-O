"""``NMRSpectrum`` — convenience view over a 1-D NMR ``Spectrum``."""
from __future__ import annotations

from dataclasses import dataclass

from .signal_array import SignalArray
from .spectrum import Spectrum


@dataclass(slots=True)
class NMRSpectrum(Spectrum):
    """A 1-D NMR spectrum with ``chemical_shift`` and ``intensity`` channels."""

    CHEMICAL_SHIFT = "chemical_shift"
    INTENSITY = "intensity"

    nucleus: str = ""

    @property
    def chemical_shift_array(self) -> SignalArray:
        return self.channel(self.CHEMICAL_SHIFT)

    @property
    def intensity_array(self) -> SignalArray:
        return self.channel(self.INTENSITY)
