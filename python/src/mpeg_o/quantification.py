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

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOQuantification`` · Java:
    ``com.dtwthalion.mpgo.Quantification``.
    """

    chemical_entity: str
    sample_ref: str
    abundance: float
    normalization_method: str = ""
