"""``Provenanceable`` — W3C PROV processing-history capability."""
from __future__ import annotations

from typing import Protocol, runtime_checkable

from ..provenance import ProvenanceRecord


@runtime_checkable
class Provenanceable(Protocol):
    """Capability for objects that carry a W3C PROV-compatible chain
    of processing records.

    Every transformation applied to the data contributes an entry;
    the chain makes the object self-documenting and supports
    regulatory audit trails.

    Methods
    -------
    add_processing_step(step)
        Append a ``ProvenanceRecord`` to the chain.
    provenance_chain()
        Return the full chain in insertion order.
    input_entities()
        Return the distinct input entity identifiers referenced by the
        chain.
    output_entities()
        Return the distinct output entity identifiers referenced by
        the chain.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOProvenanceable`` ·
    Java: ``global.thalion.ttio.protocols.Provenanceable``
    """

    def add_processing_step(self, step: ProvenanceRecord) -> None: ...
    def provenance_chain(self) -> list[ProvenanceRecord]: ...
    def input_entities(self) -> list[str]: ...
    def output_entities(self) -> list[str]: ...
