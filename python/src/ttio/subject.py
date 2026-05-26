"""``Subject`` — study donor / patient / animal / object first-class entity.

See design spec ``docs/superpowers/specs/2026-05-26-subjects-samples-design.md``
sections 4.1 and 5 for the data model and on-disk layout. Stage 6 of
transport-spec v0.11 (Deferral 2) makes this a first-class TTI-O entity
persisted as ``/study/subjects/<external_id>/`` per-row HDF5 groups.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class Subject:
    """A study Subject: the donor / patient / animal / object the
    sample was drawn from.

    Parameters
    ----------
    external_id : str
        Stable, depositor-controlled identifier; primary key within the
        dataset. Required, non-empty, must not contain ``'/'`` (HDF5
        group-name restriction, see format-spec §11).
    project : str, default ""
        Study acronym / cohort identifier. Free string. ``""`` = unset.
    sex : str, default ""
        Free string (e.g. ``"M"``, ``"F"``, ``"NA"``). No enumeration
        enforced. ``""`` = unset.
    birth_year : int, default 0
        Four-digit year of birth, or ``0`` sentinel for unknown. Stored
        as int64 on disk; widened to int32 in the
        ``SUBJECT_METADATA`` Arrow transport payload (column-width
        consistency with the identification table).
    attributes : dict[str, str], default {}
        Open extension slot. Keys are free strings; values are
        stringified. Serialised on disk as a sort-keys JSON object so
        the bytes are deterministic across Python / ObjC / Java.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOSubject`` · Java:
    ``global.thalion.ttio.Subject``.
    """

    external_id: str
    project: str = ""
    sex: str = ""
    birth_year: int = 0  # 0 = unknown sentinel
    attributes: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.external_id:
            raise ValueError("Subject.external_id must be non-empty")
        if "/" in self.external_id:
            raise ValueError(
                f"Subject.external_id may not contain '/': {self.external_id!r}"
            )

    def attributes_json(self) -> str:
        """Return the JSON serialisation of :attr:`attributes` with
        sorted keys. Matches Java's ``Subject.attributesJson()`` and
        ObjC ``NSJSONWritingSortedKeys`` byte-for-byte — required for
        cross-language transport-spec v0.11 conformance. Returns
        ``"{}"`` for an empty map.
        """
        if not self.attributes:
            return "{}"
        return json.dumps(self.attributes, sort_keys=True, separators=(",", ":"))
