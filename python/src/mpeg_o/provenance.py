"""``ProvenanceRecord`` — one row in a dataset-level provenance chain."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True, slots=True)
class ProvenanceRecord:
    """A single provenance step describing how data was produced or
    transformed. Matches the compound schema in §6.3 of ``docs/format-spec.md``.
    """

    timestamp_unix: int
    software: str
    parameters: dict[str, Any] = field(default_factory=dict)
    input_refs: list[str] = field(default_factory=list)
    output_refs: list[str] = field(default_factory=list)
