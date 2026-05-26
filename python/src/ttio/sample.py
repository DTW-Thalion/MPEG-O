"""``Sample`` — biological / material sample first-class entity.

See design spec ``docs/superpowers/specs/2026-05-26-subjects-samples-design.md``
sections 4.2 and 5 for the data model and on-disk layout. Stage 6 of
transport-spec v0.11 (Deferral 2) makes this a first-class TTI-O entity
persisted as ``/study/samples/<sample_id>/`` per-row HDF5 groups.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class Sample:
    """A biological / material Sample collected from a
    :class:`~ttio.subject.Subject`, or a standalone sample with no
    recorded subject.

    The :attr:`sample_id` matches
    :attr:`~ttio.acquisition_run.AcquisitionRun.sample_name` for the
    run → sample link; that string remains the canonical link (no
    breaking change in Stage 6). When both Sample rows and
    ``AcquisitionRun.sample_name`` are present, applications SHOULD
    treat ``sample_name`` as a foreign key into the Sample list. No
    automatic enrichment.

    Parameters
    ----------
    sample_id : str
        Stable, depositor-controlled identifier; primary key within
        the dataset. Required, non-empty, must not contain ``'/'``
        (HDF5 group-name restriction, see format-spec §11).
    subject_external_id : str, default ""
        Soft foreign key into the Subject list of the same dataset.
        Absent / unset = ``""``. A mismatch (non-empty value but no
        matching Subject) logs a WARNING during write; it is not an
        error.
    sample_kind : str, default ""
        Free string (e.g. ``"tissue"``, ``"plasma"``). ``""`` = unset.
    collected_at : int, default 0
        Unix seconds since epoch when the sample was collected, or
        ``0`` sentinel for unknown. Stored as int64 on disk and in
        the ``SAMPLE_METADATA`` Arrow transport payload.
    attributes : dict[str, str], default {}
        Open extension slot. Keys are free strings; values are
        stringified. Serialised on disk as a sort-keys JSON object so
        the bytes are deterministic across Python / ObjC / Java.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOSample`` · Java:
    ``global.thalion.ttio.Sample``.
    """

    sample_id: str
    subject_external_id: str = ""
    sample_kind: str = ""
    collected_at: int = 0  # 0 = unknown sentinel
    attributes: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.sample_id:
            raise ValueError("Sample.sample_id must be non-empty")
        if "/" in self.sample_id:
            raise ValueError(
                f"Sample.sample_id may not contain '/': {self.sample_id!r}"
            )

    def attributes_json(self) -> str:
        """Return the JSON serialisation of :attr:`attributes` with
        sorted keys. Matches Java's ``Sample.attributesJson()`` and
        ObjC ``NSJSONWritingSortedKeys`` byte-for-byte — required for
        cross-language transport-spec v0.11 conformance. Returns
        ``"{}"`` for an empty map.
        """
        if not self.attributes:
            return "{}"
        return json.dumps(self.attributes, sort_keys=True, separators=(",", ":"))
