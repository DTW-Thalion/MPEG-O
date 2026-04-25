"""``IsolationWindow`` — precursor isolation window for MS/MS scans."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class IsolationWindow:
    """Precursor isolation window, expressed as a target m/z with
    asymmetric lower/upper offsets in Th (Da).

    The instrument-reported window spans
    ``[target_mz - lower_offset, target_mz + upper_offset]``. Offsets are
    non-negative by convention; the lower and upper may differ when the
    quadrupole is offset from the monoisotopic m/z (common in DIA).

    Parameters
    ----------
    target_mz : float
        Center of the isolation window in Th (Da).
    lower_offset : float
        Distance from ``target_mz`` to the lower bound, in Th. Non-negative.
    upper_offset : float
        Distance from ``target_mz`` to the upper bound, in Th. Non-negative.

    Notes
    -----
    API status: Stable (v1.1, M74).

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOIsolationWindow`` · Java:
    ``com.dtwthalion.ttio.IsolationWindow``.
    """

    target_mz: float
    lower_offset: float
    upper_offset: float

    @property
    def lower_bound(self) -> float:
        """Lower m/z bound ``target_mz - lower_offset``."""
        return self.target_mz - self.lower_offset

    @property
    def upper_bound(self) -> float:
        """Upper m/z bound ``target_mz + upper_offset``."""
        return self.target_mz + self.upper_offset

    @property
    def width(self) -> float:
        """Total isolation width ``lower_offset + upper_offset``."""
        return self.lower_offset + self.upper_offset
