"""``IRSpectrum`` — 1-D infrared spectrum subclass."""
from __future__ import annotations

from dataclasses import dataclass

from .enums import IRMode
from .signal_array import SignalArray
from .spectrum import Spectrum


@dataclass(slots=True)
class IRSpectrum(Spectrum):
    """A 1-D infrared spectrum with ``wavenumber`` and ``intensity`` channels.

    Parameters
    ----------
    mode : IRMode, default ``IRMode.TRANSMITTANCE``
        Whether y-values are absorbance or transmittance.
    resolution_cm_inv : float, default 0.0
        Spectral resolution in reciprocal centimetres.
    number_of_scans : int, default 0
        Number of co-added scans producing this spectrum.
    *plus all base :class:`Spectrum` parameters*

    Notes
    -----
    API status: Stable (v0.11, M73).

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOIRSpectrum`` · Java:
    ``com.dtwthalion.ttio.IRSpectrum``.
    """

    WAVENUMBER = "wavenumber"
    INTENSITY = "intensity"

    mode: IRMode = IRMode.TRANSMITTANCE
    resolution_cm_inv: float = 0.0
    number_of_scans: int = 0

    @property
    def wavenumber_array(self) -> SignalArray:
        """Return the ``"wavenumber"`` :class:`SignalArray`."""
        return self.signal_array(self.WAVENUMBER)

    @property
    def intensity_array(self) -> SignalArray:
        """Return the ``"intensity"`` :class:`SignalArray`."""
        return self.signal_array(self.INTENSITY)
