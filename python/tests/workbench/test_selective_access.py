"""
Unit tests for `ttio.workbench.transport.selective_access`. Pure
data; no daemon.

Cross-language anchor: the literal filter dict pinned in
`test_canonical_filter_anchor` is mirrored by the Java
`SelectiveAccessFilterTest.canonicalFilterAnchor`. Drift in
either client fails both suites.
"""
from __future__ import annotations

import pytest

from ttio.workbench.transport.selective_access import (
    ALLOWED_POLARITIES,
    SelectiveAccessFilter,
)


# ---------------------------------------------------- accepting inputs

def test_ms_level_accepts_positive():
    f = SelectiveAccessFilter().ms_level(2).build()
    assert f == {"ms_level": 2}


def test_polarity_accepts_known():
    assert SelectiveAccessFilter().polarity("positive").build() == {
        "polarity": "positive"}
    assert SelectiveAccessFilter().polarity("negative").build() == {
        "polarity": "negative"}


def test_polarity_none_clears_field():
    b = SelectiveAccessFilter().polarity("positive")
    assert "polarity" in b.build()
    b.polarity(None)
    assert "polarity" not in b.build()


def test_retention_time_range():
    f = (SelectiveAccessFilter()
            .retention_time_min(12.5)
            .retention_time_max(25.0)
            .validate()
            .build())
    assert f == {"retention_time_min": 12.5, "retention_time_max": 25.0}


def test_precursor_mz_range_and_charge():
    f = (SelectiveAccessFilter()
            .precursor_mz_min(100.0)
            .precursor_mz_max(2000.0)
            .precursor_charge(2)
            .validate()
            .build())
    assert f == {
        "precursor_mz_min": 100.0,
        "precursor_mz_max": 2000.0,
        "precursor_charge": 2,
    }


def test_max_au():
    assert SelectiveAccessFilter().max_au(50).build() == {"max_au": 50}


def test_empty_builder():
    b = SelectiveAccessFilter()
    assert b.is_empty()
    assert len(b) == 0
    assert b.build() == {}


# ---------------------------------------------------- rejecting inputs

def test_ms_level_rejects_zero_and_negative():
    with pytest.raises(ValueError, match="ms_level"):
        SelectiveAccessFilter().ms_level(0)
    with pytest.raises(ValueError, match="ms_level"):
        SelectiveAccessFilter().ms_level(-1)


def test_polarity_rejects_unknown():
    with pytest.raises(ValueError, match="polarity"):
        SelectiveAccessFilter().polarity("both")
    with pytest.raises(ValueError, match="polarity"):
        SelectiveAccessFilter().polarity("POSITIVE")  # case-sensitive


def test_rt_min_rejects_negative():
    with pytest.raises(ValueError, match="retention_time_min"):
        SelectiveAccessFilter().retention_time_min(-0.5)


def test_rt_max_rejects_negative():
    with pytest.raises(ValueError, match="retention_time_max"):
        SelectiveAccessFilter().retention_time_max(-0.5)


def test_mz_min_rejects_negative():
    with pytest.raises(ValueError, match="precursor_mz_min"):
        SelectiveAccessFilter().precursor_mz_min(-0.1)


def test_max_au_rejects_zero():
    with pytest.raises(ValueError, match="max_au"):
        SelectiveAccessFilter().max_au(0)


# ---------------------------------------------------- cross-key validation

def test_validate_catches_inverted_rt_range():
    b = (SelectiveAccessFilter()
            .retention_time_min(20.0)
            .retention_time_max(10.0))
    with pytest.raises(RuntimeError, match="retention_time_max"):
        b.validate()


def test_validate_catches_inverted_mz_range():
    b = (SelectiveAccessFilter()
            .precursor_mz_min(2000.0)
            .precursor_mz_max(100.0))
    with pytest.raises(RuntimeError, match="precursor_mz_max"):
        b.validate()


def test_validate_passes_equal_range():
    # rt_max == rt_min is allowed (single retention-time slice).
    (SelectiveAccessFilter()
        .retention_time_min(15.0)
        .retention_time_max(15.0)
        .validate())


# ---------------------------------------------------- cross-language anchor

def test_canonical_filter_anchor():
    """Cross-language anchor: this exact builder input must produce
    a byte-identical filter dict in Python and Java.

    Java mirror: `SelectiveAccessFilterTest.canonicalFilterAnchor`.
    """
    f = (SelectiveAccessFilter()
            .ms_level(2)
            .polarity("positive")
            .retention_time_min(12.5)
            .retention_time_max(25.0)
            .precursor_mz_min(100.0)
            .precursor_mz_max(2000.0)
            .precursor_charge(2)
            .max_au(50)
            .validate()
            .build())
    assert f == {
        "ms_level":          2,
        "polarity":          "positive",
        "retention_time_min": 12.5,
        "retention_time_max": 25.0,
        "precursor_mz_min":  100.0,
        "precursor_mz_max":  2000.0,
        "precursor_charge":  2,
        "max_au":            50,
    }


# ---------------------------------------------------- module constant

def test_allowed_polarities_set():
    assert ALLOWED_POLARITIES == frozenset({"positive", "negative"})
