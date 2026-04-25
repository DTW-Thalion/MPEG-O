"""``CVAnnotatable`` — controlled-vocabulary annotation capability."""
from __future__ import annotations

from typing import Protocol, runtime_checkable

from ..cv_param import CVParam


@runtime_checkable
class CVAnnotatable(Protocol):
    """Capability for objects that can be tagged with controlled-vocabulary
    parameters from any ontology (PSI-MS, nmrCV, CHEBI, BFO, ...).

    This is the primary extensibility mechanism in TTI-O: the schema
    stays minimal while semantic richness lives in curated external
    ontologies.

    Methods
    -------
    add_cv_param(param)
        Attach a ``CVParam`` to this object.
    remove_cv_param(param)
        Detach a previously-attached ``CVParam``. No-op if absent.
    all_cv_params()
        Return every attached ``CVParam`` in insertion order.
    cv_params_for_accession(accession)
        Return every attached ``CVParam`` whose ``accession`` matches.
    cv_params_for_ontology_ref(ontology_ref)
        Return every attached ``CVParam`` whose ``ontology_ref`` matches.
    has_cv_param_with_accession(accession)
        Return ``True`` if at least one attached ``CVParam`` matches.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOCVAnnotatable`` ·
    Java: ``com.dtwthalion.ttio.protocols.CVAnnotatable``
    """

    def add_cv_param(self, param: CVParam) -> None: ...
    def remove_cv_param(self, param: CVParam) -> None: ...
    def all_cv_params(self) -> list[CVParam]: ...
    def cv_params_for_accession(self, accession: str) -> list[CVParam]: ...
    def cv_params_for_ontology_ref(self, ontology_ref: str) -> list[CVParam]: ...
    def has_cv_param_with_accession(self, accession: str) -> bool: ...
