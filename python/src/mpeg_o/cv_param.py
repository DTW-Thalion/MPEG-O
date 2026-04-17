"""``CVParam`` — controlled-vocabulary parameter reference."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class CVParam:
    """A single controlled-vocabulary parameter reference.

    Immutable value class in the form
    ``(ontology_ref, accession, name, [value], [unit])``.

    Parameters
    ----------
    ontology_ref : str
        Ontology short name (``"MS"``, ``"NMR"``, ``"UO"``, ...).
    accession : str
        Ontology accession in ``<CV>:<id>`` form
        (e.g. ``"MS:1000515"``).
    name : str
        Human-readable label.
    value : str, default ""
        Optional free-form value. Use an empty string when the
        parameter is a pure assertion with no associated value.
    unit : str or None, default None
        Optional unit accession (typically a UO or MS term).

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOCVParam`` · Java:
    ``com.dtwthalion.mpgo.CVParam``.
    """

    ontology_ref: str
    accession: str
    name: str
    value: str = ""
    unit: str | None = None
