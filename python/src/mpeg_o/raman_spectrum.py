"""``RamanSpectrum`` — 1-D Raman spectrum subclass."""
from __future__ import annotations

from dataclasses import dataclass

from .signal_array import SignalArray
from .spectrum import Spectrum


@dataclass(slots=True)
class RamanSpectrum(Spectrum):
    """A 1-D Raman spectrum with ``wavenumber`` and ``intensity`` channels.

    Parameters
    ----------
    excitation_wavelength_nm : float, default 0.0
        Laser excitation wavelength in nanometres (e.g. 532, 785).
    laser_power_mw : float, default 0.0
        Incident laser power in milliwatts.
    integration_time_sec : float, default 0.0
        Detector integration time in seconds.
    *plus all base :class:`Spectrum` parameters*

    Notes
    -----
    API status: Stable (v0.11, M73).

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGORamanSpectrum`` · Java:
    ``com.dtwthalion.mpgo.RamanSpectrum``.
    """

    WAVENUMBER = "wavenumber"
    INTENSITY = "intensity"

    excitation_wavelength_nm: float = 0.0
    laser_power_mw: float = 0.0
    integration_time_sec: float = 0.0

    @property
    def wavenumber_array(self) -> SignalArray:
        """Return the ``"wavenumber"`` :class:`SignalArray`."""
        return self.signal_array(self.WAVENUMBER)

    @property
    def intensity_array(self) -> SignalArray:
        """Return the ``"intensity"`` :class:`SignalArray`."""
        return self.signal_array(self.INTENSITY)
