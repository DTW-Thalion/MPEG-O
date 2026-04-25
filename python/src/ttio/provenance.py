"""``ProvenanceRecord`` — one row in a dataset-level provenance chain."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True, slots=True)
class ProvenanceRecord:
    """A single provenance step describing how data was produced or
    transformed. W3C PROV-compatible.

    Parameters
    ----------
    timestamp_unix : int, default 0
        Unix timestamp (seconds since 1970-01-01T00:00:00Z).
    software : str, default ""
        Software name + version (e.g. ``"MSConvert 3.0.24052"``).
    parameters : dict[str, Any], default {}
        Software-specific processing parameters.
    input_refs : list[str], default []
        URIs / identifiers of input entities.
    output_refs : list[str], default []
        URIs / identifiers of output entities.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOProvenanceRecord`` · Java:
    ``global.thalion.ttio.ProvenanceRecord``.
    """

    timestamp_unix: int = 0
    software: str = ""
    parameters: dict[str, Any] = field(default_factory=dict)
    input_refs: list[str] = field(default_factory=list)
    output_refs: list[str] = field(default_factory=list)

    def contains_input_ref(self, ref: str) -> bool:
        """Return ``True`` iff ``ref`` is in ``input_refs``."""
        return ref in self.input_refs
