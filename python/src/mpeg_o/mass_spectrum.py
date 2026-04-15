"""``MassSpectrum`` — convenience view over an MS ``Spectrum``."""
from __future__ import annotations

from dataclasses import dataclass

from .signal_array import SignalArray
from .spectrum import Spectrum


@dataclass(slots=True)
class MassSpectrum(Spectrum):
    """An MS spectrum whose standard channels are ``mz`` and ``intensity``."""

    MZ = "mz"
    INTENSITY = "intensity"

    @property
    def mz_array(self) -> SignalArray:
        return self.channel(self.MZ)

    @property
    def intensity_array(self) -> SignalArray:
        return self.channel(self.INTENSITY)
