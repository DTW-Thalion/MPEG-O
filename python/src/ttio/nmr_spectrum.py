"""``NMRSpectrum`` — 1-D NMR subclass with chemical-shift + intensity."""
from __future__ import annotations

from dataclasses import dataclass

from .signal_array import SignalArray
from .spectrum import Spectrum


@dataclass(slots=True)
class NMRSpectrum(Spectrum):
    """A 1-D NMR spectrum with ``chemical_shift`` and ``intensity`` channels.

    Parameters
    ----------
    nucleus_type : str, default ""
        Nucleus type (``"1H"``, ``"13C"``, ``"31P"``, ...).
    spectrometer_frequency_mhz : float, default 0.0
        Spectrometer frequency in MHz.
    *plus all base :class:`Spectrum` parameters*

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIONMRSpectrum`` · Java:
    ``global.thalion.ttio.NMRSpectrum``.
    """

    CHEMICAL_SHIFT = "chemical_shift"
    INTENSITY = "intensity"

    nucleus_type: str = ""
    spectrometer_frequency_mhz: float = 0.0

    @property
    def chemical_shift_array(self) -> SignalArray:
        """Return the ``"chemical_shift"`` :class:`SignalArray`."""
        return self.signal_array(self.CHEMICAL_SHIFT)

    @property
    def intensity_array(self) -> SignalArray:
        """Return the ``"intensity"`` :class:`SignalArray`."""
        return self.signal_array(self.INTENSITY)
