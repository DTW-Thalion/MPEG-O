"""``Identification`` — spectrum-to-chemical-entity assignment record."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class Identification:
    """A spectrum-level chemical-entity identification.

    Links a spectrum (by its 0-based index within an acquisition run)
    to a chemical entity with a confidence score and an evidence
    chain.

    Parameters
    ----------
    run_name : str
        Acquisition run that contains the spectrum.
    spectrum_index : int
        0-based position within that run.
    chemical_entity : str
        CHEBI accession or chemical formula.
    confidence_score : float
        Score in ``[0.0, 1.0]``.
    evidence_chain : list[str], default []
        Ordered list of free-form evidence strings (typically CV
        accession references).

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOIdentification`` · Java:
    ``global.thalion.ttio.Identification``.
    """

    run_name: str
    spectrum_index: int
    chemical_entity: str
    confidence_score: float
    evidence_chain: list[str] = field(default_factory=list)
