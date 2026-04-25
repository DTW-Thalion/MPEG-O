"""``UVVisSpectrum`` — 1-D UV-visible absorption spectrum subclass."""
from __future__ import annotations

from dataclasses import dataclass

from .signal_array import SignalArray
from .spectrum import Spectrum


@dataclass(slots=True)
class UVVisSpectrum(Spectrum):
    """A 1-D UV-Vis spectrum with ``wavelength`` (nm) and ``absorbance`` channels.

    Unlike Raman / IR spectra, UV-Vis observations are indexed by
    wavelength in nanometres rather than wavenumber.

    Parameters
    ----------
    path_length_cm : float, default 0.0
        Optical path length of the cuvette in centimetres.
    solvent : str, default ``""``
        Free-form solvent description (e.g. ``"methanol"``).
    *plus all base :class:`Spectrum` parameters*

    Notes
    -----
    API status: Stable (v0.11.1).

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOUVVisSpectrum`` · Java:
    ``global.thalion.ttio.UVVisSpectrum``.
    """

    WAVELENGTH = "wavelength"
    ABSORBANCE = "absorbance"

    path_length_cm: float = 0.0
    solvent: str = ""

    @property
    def wavelength_array(self) -> SignalArray:
        """Return the ``"wavelength"`` :class:`SignalArray`."""
        return self.signal_array(self.WAVELENGTH)

    @property
    def absorbance_array(self) -> SignalArray:
        """Return the ``"absorbance"`` :class:`SignalArray`."""
        return self.signal_array(self.ABSORBANCE)
