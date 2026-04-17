"""``MassSpectrum`` — MS subclass with m/z + intensity channels."""
from __future__ import annotations

from dataclasses import dataclass

from .enums import Polarity
from .signal_array import SignalArray
from .spectrum import Spectrum
from .value_range import ValueRange


@dataclass(slots=True)
class MassSpectrum(Spectrum):
    """A mass spectrum: m/z + intensity arrays plus MS level, polarity,
    and an optional scan window.

    Parameters
    ----------
    ms_level : int, default 1
        MS level (1, 2, 3, ...).
    polarity : Polarity, default Polarity.UNKNOWN
        Ion polarity.
    scan_window : ValueRange or None, default None
        m/z range covered by the scan. ``None`` if not reported.
    *plus all base :class:`Spectrum` parameters (signal_arrays, axes,
    index_position, scan_time_seconds, precursor_mz, precursor_charge)*

    Notes
    -----
    API status: Stable.

    Standard channel names are ``"mz"`` and ``"intensity"``.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOMassSpectrum`` · Java:
    ``com.dtwthalion.mpgo.MassSpectrum``.
    """

    MZ = "mz"
    INTENSITY = "intensity"

    ms_level: int = 1
    polarity: Polarity = Polarity.UNKNOWN
    scan_window: ValueRange | None = None

    @property
    def mz_array(self) -> SignalArray:
        """Return the ``"mz"`` :class:`SignalArray`. Raises if absent."""
        return self.signal_array(self.MZ)

    @property
    def intensity_array(self) -> SignalArray:
        """Return the ``"intensity"`` :class:`SignalArray`."""
        return self.signal_array(self.INTENSITY)
