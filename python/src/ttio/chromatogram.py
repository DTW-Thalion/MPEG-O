"""``Chromatogram`` — time-vs-intensity Spectrum subclass."""
from __future__ import annotations

from dataclasses import dataclass

from .enums import ChromatogramType
from .signal_array import SignalArray
from .spectrum import Spectrum


@dataclass(slots=True)
class Chromatogram(Spectrum):
    """Chromatogram: time-vs-intensity trace. TIC, XIC, or SRM.

    Subclass of :class:`Spectrum`. The time and intensity arrays live
    in :attr:`signal_arrays` under keys ``"time"`` and ``"intensity"``.

    Parameters
    ----------
    chromatogram_type : ChromatogramType, default ChromatogramType.TIC
        TIC / XIC / SRM.
    target_mz : float, default 0.0
        XIC target m/z. ``0`` if not XIC.
    product_mz : float, default 0.0
        SRM product m/z. ``0`` if not SRM.
    *plus all base :class:`Spectrum` parameters*

    Notes
    -----
    API status: Stable.

    Standard channel names are ``"time"`` and ``"intensity"``.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOChromatogram`` · Java:
    ``com.dtwthalion.ttio.Chromatogram``.
    """

    TIME = "time"
    INTENSITY = "intensity"

    chromatogram_type: ChromatogramType = ChromatogramType.TIC
    target_mz: float = 0.0
    product_mz: float = 0.0

    @property
    def time_array(self) -> SignalArray:
        """Return the ``"time"`` :class:`SignalArray`."""
        return self.signal_array(self.TIME)

    @property
    def intensity_array(self) -> SignalArray:
        """Return the ``"intensity"`` :class:`SignalArray`."""
        return self.signal_array(self.INTENSITY)
