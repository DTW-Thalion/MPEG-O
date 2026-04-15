"""``CVParam`` — controlled-vocabulary parameter (PSI-MS, nmrCV, ...)."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class CVParam:
    """A controlled-vocabulary parameter reference.

    Mirrors the ObjC ``MPGOCVParam`` value class. ``accession`` follows the
    ``<CV>:<id>`` form used by PSI-MS (e.g. ``"MS:1000515"``) or nmrCV
    (e.g. ``"NMR:1000002"``). ``unit_accession`` may be ``None``.
    """

    accession: str
    name: str
    value: str = ""
    unit_accession: str | None = None
    unit_name: str | None = None
