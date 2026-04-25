"""``TransitionList`` — targeted SRM/MRM transition collection."""
from __future__ import annotations

from dataclasses import dataclass, field

from .value_range import ValueRange


@dataclass(frozen=True, slots=True)
class Transition:
    """One SRM/MRM transition.

    Parameters
    ----------
    precursor_mz : float
        Precursor m/z.
    product_mz : float
        Product m/z.
    collision_energy : float, default 0.0
        Collision energy (eV).
    retention_time_window : ValueRange or None, default None
        Optional retention-time acceptance window.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOTransition`` · Java:
    ``com.dtwthalion.ttio.TransitionList.Transition``.
    """

    precursor_mz: float
    product_mz: float
    collision_energy: float = 0.0
    retention_time_window: ValueRange | None = None


@dataclass(frozen=True, slots=True)
class TransitionList:
    """An ordered collection of SRM/MRM transitions.

    Parameters
    ----------
    transitions : tuple[Transition, ...], default ()
        Ordered transitions.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOTransitionList`` · Java:
    ``com.dtwthalion.ttio.TransitionList``.
    """

    transitions: tuple[Transition, ...] = field(default_factory=tuple)

    def __len__(self) -> int:
        return len(self.transitions)

    def count(self) -> int:
        """Return the number of transitions."""
        return len(self.transitions)

    def transition_at_index(self, index: int) -> Transition:
        """Return the transition at ``index``."""
        return self.transitions[index]
