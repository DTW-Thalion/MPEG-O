"""``Quantification`` — chemical-entity abundance record."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Quantification:
    """An abundance observation for a chemical entity in a sample.

    Parameters
    ----------
    chemical_entity : str
        CHEBI accession or chemical formula.
    sample_ref : str
        Sample identifier.
    abundance : float
        Measured abundance.
    normalization_method : str, default ""
        Normalization method. Empty string represents an unnormalized
        abundance.
    unit : str, default ""
        Free-form unit label for ``abundance`` (e.g. ``"ng/mL"``,
        ``"peak-area"``, ``"ion-count"``, ``"normalized"``). Empty when
        not specified — readers should interpret an empty unit as
        "implied by ``normalization_method``".

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOQuantification`` · Java:
    ``global.thalion.ttio.Quantification``.
    """

    chemical_entity: str
    sample_ref: str
    abundance: float
    normalization_method: str = ""
    unit: str = ""
