"""``Identification`` — spectrum-to-chemical-entity assignment record."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class Identification:
    """A spectrum-level chemical-entity identification.

    Matches the ``identifications`` compound dataset schema in §6.1 of
    ``docs/format-spec.md``.
    """

    run_name: str
    spectrum_index: int
    chemical_entity: str
    confidence_score: float
    evidence_chain: list[str] = field(default_factory=list)
