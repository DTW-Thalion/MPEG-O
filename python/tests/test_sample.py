"""Stage 6 (transport-spec v0.11, Deferral 2): :class:`Sample` dataclass.

Validation rules per design spec
``docs/superpowers/specs/2026-05-26-subjects-samples-design.md`` §4.4.
Java parity: ``SpectralDatasetSubjectsSamplesTest``.
"""
from __future__ import annotations

import pytest

from ttio.sample import Sample


def test_minimal_sample_only_sample_id_required():
    s = Sample(sample_id="bio1")
    assert s.sample_id == "bio1"
    assert s.subject_external_id == ""
    assert s.sample_kind == ""
    assert s.collected_at == 0
    assert s.attributes == {}


def test_empty_sample_id_raises():
    with pytest.raises(ValueError, match="must be non-empty"):
        Sample(sample_id="")


def test_slash_in_sample_id_raises():
    with pytest.raises(ValueError, match="may not contain '/'"):
        Sample(sample_id="bio/1")


def test_attributes_json_empty_returns_braces():
    assert Sample(sample_id="bio1").attributes_json() == "{}"


def test_attributes_json_sorted_keys():
    s = Sample(
        sample_id="bio1",
        attributes={"site": "NYC", "ph": "7.4"},
    )
    assert s.attributes_json() == '{"ph":"7.4","site":"NYC"}'


def test_collected_at_sentinel_zero_is_default():
    s = Sample(sample_id="bio1")
    assert s.collected_at == 0


def test_all_fields_populated():
    s = Sample(
        sample_id="bio1",
        subject_external_id="S1",
        sample_kind="tissue",
        collected_at=1700000000,
        attributes={"cohort": "A1"},
    )
    assert s.sample_id == "bio1"
    assert s.subject_external_id == "S1"
    assert s.sample_kind == "tissue"
    assert s.collected_at == 1700000000
    assert s.attributes == {"cohort": "A1"}


def test_frozen_dataclass_blocks_mutation():
    s = Sample(sample_id="bio1")
    with pytest.raises((AttributeError, Exception)):
        s.sample_id = "bio2"  # type: ignore[misc]
