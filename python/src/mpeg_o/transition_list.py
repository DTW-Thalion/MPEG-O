"""``TransitionList`` — targeted SRM/MRM transition collection."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class Transition:
    """A single SRM/MRM transition: precursor → product with CE and RT window."""

    precursor_mz: float
    product_mz: float
    collision_energy: float = 0.0
    retention_time_window: tuple[float, float] | None = None
    label: str = ""


@dataclass(frozen=True, slots=True)
class TransitionList:
    """An ordered collection of SRM/MRM transitions."""

    transitions: tuple[Transition, ...] = field(default_factory=tuple)

    def __len__(self) -> int:
        return len(self.transitions)
