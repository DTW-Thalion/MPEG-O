"""``ValueRange`` — inclusive numeric interval used for axis bounds."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ValueRange:
    """An inclusive numeric interval ``[minimum, maximum]``.

    Immutable value class. Empty or inverted ranges are permitted at
    construction time; consumers decide whether ``minimum > maximum``
    is meaningful in their context.

    Parameters
    ----------
    minimum : float
        Lower bound (inclusive).
    maximum : float
        Upper bound (inclusive).

    Attributes
    ----------
    span : float
        Difference ``maximum - minimum``.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOValueRange`` · Java:
    ``global.thalion.ttio.ValueRange``.
    """

    minimum: float
    maximum: float

    def contains(self, value: float) -> bool:
        """Return ``True`` if ``value`` lies within the closed range.

        Parameters
        ----------
        value : float

        Returns
        -------
        bool
        """
        return self.minimum <= value <= self.maximum

    @property
    def span(self) -> float:
        """Difference between ``maximum`` and ``minimum``."""
        return self.maximum - self.minimum
