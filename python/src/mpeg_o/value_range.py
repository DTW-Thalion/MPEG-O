"""``ValueRange`` — inclusive numeric interval used for axis bounds."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ValueRange:
    """An inclusive numeric interval ``[minimum, maximum]``.

    Instances are immutable value objects. Empty or inverted ranges are
    permitted at construction time; consumers are responsible for deciding
    whether ``minimum > maximum`` is meaningful in their context.
    """

    minimum: float
    maximum: float

    def contains(self, value: float) -> bool:
        return self.minimum <= value <= self.maximum

    @property
    def span(self) -> float:
        return self.maximum - self.minimum
