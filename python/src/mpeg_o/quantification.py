"""``Quantification`` — chemical-entity abundance record."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Quantification:
    """An abundance observation for a chemical entity in a sample.

    Matches the ``quantifications`` compound dataset schema in §6.2 of
    ``docs/format-spec.md``. ``normalization_method`` of ``""`` represents
    an unnormalized abundance.
    """

    chemical_entity: str
    sample_ref: str
    abundance: float
    normalization_method: str = ""
