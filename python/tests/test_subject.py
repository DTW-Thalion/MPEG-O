"""Stage 6 (transport-spec v0.11, Deferral 2): :class:`Subject` dataclass.

Validation rules per design spec
``docs/superpowers/specs/2026-05-26-subjects-samples-design.md`` §4.4.
Java parity: ``SpectralDatasetSubjectsSamplesTest``.
"""
from __future__ import annotations

import pytest

from ttio.subject import Subject


def test_minimal_subject_only_external_id_required():
    s = Subject(external_id="S1")
    assert s.external_id == "S1"
    assert s.project == ""
    assert s.sex == ""
    assert s.birth_year == 0
    assert s.attributes == {}


def test_empty_external_id_raises():
    with pytest.raises(ValueError, match="must be non-empty"):
        Subject(external_id="")


def test_slash_in_external_id_raises():
    with pytest.raises(ValueError, match="may not contain '/'"):
        Subject(external_id="patient/01")


def test_attributes_json_empty_returns_braces():
    assert Subject(external_id="S1").attributes_json() == "{}"


def test_attributes_json_sorted_keys_no_whitespace():
    s = Subject(
        external_id="S1",
        attributes={"zeta": "z", "alpha": "a", "mu": "m"},
    )
    # Sorted keys + compact separators.
    assert s.attributes_json() == '{"alpha":"a","mu":"m","zeta":"z"}'


def test_attributes_json_multi_key_preservation():
    attrs = {"site": "NYC", "cohort": "A1", "race": "white"}
    s = Subject(external_id="S1", attributes=attrs)
    expected = '{"cohort":"A1","race":"white","site":"NYC"}'
    assert s.attributes_json() == expected


def test_attributes_json_special_chars():
    """Quotes inside values must remain JSON-valid."""
    import json
    attrs = {"note": 'has "quoted" text', "k": "v\nnewline"}
    s = Subject(external_id="S1", attributes=attrs)
    # Round-trip via json.loads so the byte-shape stays parseable.
    parsed = json.loads(s.attributes_json())
    assert parsed == attrs


def test_frozen_dataclass_blocks_mutation():
    s = Subject(external_id="S1")
    with pytest.raises((AttributeError, Exception)):
        s.external_id = "S2"  # type: ignore[misc]


def test_birth_year_sentinel_zero_is_default():
    s = Subject(external_id="S1")
    assert s.birth_year == 0


def test_all_fields_populated():
    s = Subject(
        external_id="S1",
        project="STUDY-A",
        sex="F",
        birth_year=1985,
        attributes={"site": "NYC"},
    )
    assert s.external_id == "S1"
    assert s.project == "STUDY-A"
    assert s.sex == "F"
    assert s.birth_year == 1985
    assert s.attributes == {"site": "NYC"}
