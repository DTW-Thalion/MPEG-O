"""
Unit tests for `ttio.workbench.cohort` -- predicate AST + JSON
serialisation. Pure data; no daemon.
"""
from __future__ import annotations

import json

import pytest

from ttio.workbench.cohort import (
    ALLOWED_CONTAINER_FIELDS,
    ALLOWED_OPS,
    ALLOWED_SAMPLE_FIELDS,
    ALLOWED_SELECT,
    ALLOWED_SUBJECT_FIELDS,
    AndPredicate,
    CohortQuery,
    CohortResult,
    ContainerFieldPredicate,
    NotPredicate,
    OrPredicate,
    PhenotypePredicate,
    SampleFieldPredicate,
    SubjectFieldPredicate,
    container,
    phenotype,
    sample,
    subject,
)


# ---------------------------------------------------- allow-list constants

def test_allow_list_container_fields():
    # Pinning these prevents drift if a future server bump adds or
    # removes a column without updating the client.
    assert ALLOWED_CONTAINER_FIELDS == {
        "project", "owner", "encrypted",
        "created_at", "updated_at", "uri",
    }


def test_allow_list_subject_fields():
    assert ALLOWED_SUBJECT_FIELDS == {
        "project", "external_id", "sex", "birth_year",
    }


def test_allow_list_sample_fields():
    assert ALLOWED_SAMPLE_FIELDS == {"sample_kind", "collected_at"}


def test_allow_list_ops():
    assert ALLOWED_OPS == {
        "eq", "ne", "lt", "gt", "le", "ge", "in", "like", "exists",
    }


def test_allow_list_select():
    assert ALLOWED_SELECT == {"containers", "subjects", "samples"}


# ---------------------------------------------------- leaf predicates

def test_container_leaf_to_json():
    p = container("project", "eq", "alpha")
    assert p.to_json() == {
        "container_field": "project", "op": "eq", "value": "alpha",
    }


def test_subject_leaf_to_json():
    p = subject("birth_year", "gt", 1950)
    assert p.to_json() == {
        "subject_field": "birth_year", "op": "gt", "value": 1950,
    }


def test_sample_leaf_to_json():
    p = sample("sample_kind", "eq", "tissue")
    assert p.to_json() == {
        "sample_field": "sample_kind", "op": "eq", "value": "tissue",
    }


def test_phenotype_leaf_to_json():
    p = phenotype("diagnosis", "eq", "Alzheimer's")
    assert p.to_json() == {
        "phenotype": "diagnosis", "op": "eq", "value": "Alzheimer's",
    }


def test_exists_op_omits_value():
    p = container("uri", "exists")
    assert p.to_json() == {"container_field": "uri", "op": "exists"}


def test_in_op_takes_array():
    p = container("project", "in", ["alpha", "beta"])
    assert p.to_json()["value"] == ["alpha", "beta"]


def test_leaf_rejects_unknown_field():
    with pytest.raises(ValueError, match="unknown container field"):
        container("not_a_real_column", "eq", "x")


def test_leaf_rejects_unknown_op():
    with pytest.raises(ValueError, match="unknown predicate op"):
        container("project", "not_an_op", "x")


def test_phenotype_rejects_empty_name():
    with pytest.raises(ValueError, match="name"):
        phenotype("", "eq", "x")


# ---------------------------------------------------- composites

def test_and_to_json():
    p = AndPredicate([
        container("project", "eq", "alpha"),
        subject("sex", "eq", "F"),
    ])
    assert p.to_json() == {
        "op": "and",
        "children": [
            {"container_field": "project", "op": "eq", "value": "alpha"},
            {"subject_field":   "sex",     "op": "eq", "value": "F"},
        ],
    }


def test_or_to_json():
    p = OrPredicate([
        container("project", "eq", "alpha"),
        container("project", "eq", "beta"),
    ])
    assert p.to_json()["op"] == "or"
    assert len(p.to_json()["children"]) == 2


def test_not_to_json():
    p = NotPredicate(container("encrypted", "eq", True))
    assert p.to_json() == {
        "op": "not",
        "child": {"container_field": "encrypted", "op": "eq", "value": True},
    }


def test_and_requires_children():
    with pytest.raises(ValueError, match="at least one child"):
        AndPredicate([])


def test_phenotype_under_or_rejected():
    with pytest.raises(ValueError, match="cannot appear under OR"):
        OrPredicate([
            container("project", "eq", "alpha"),
            phenotype("diagnosis", "eq", "X"),
        ])


def test_phenotype_under_not_rejected():
    with pytest.raises(ValueError, match="cannot appear under NOT"):
        NotPredicate(phenotype("diagnosis", "eq", "X"))


def test_phenotype_under_nested_or_rejected():
    # Catches deep-nested violations too.
    inner = AndPredicate([
        phenotype("diagnosis", "eq", "X"),
        container("project", "eq", "alpha"),
    ])
    with pytest.raises(ValueError, match="cannot appear under OR"):
        OrPredicate([container("project", "eq", "beta"), inner])


# ---------------------------------------------------- operator sugar

def test_and_operator_sugar():
    p = container("project", "eq", "alpha") & subject("sex", "eq", "F")
    assert isinstance(p, AndPredicate)
    assert len(p.children) == 2


def test_and_operator_flattens():
    p = (
        container("project", "eq", "alpha")
        & subject("sex", "eq", "F")
        & container("owner", "eq", "alice")
    )
    assert len(p.children) == 3


def test_or_operator_sugar():
    p = container("project", "eq", "alpha") | container("project", "eq", "beta")
    assert isinstance(p, OrPredicate)


def test_invert_operator_sugar():
    p = ~container("encrypted", "eq", True)
    assert isinstance(p, NotPredicate)


# ---------------------------------------------------- CohortQuery

def test_cohort_query_minimal_to_json():
    q = CohortQuery(select="containers")
    assert q.to_json() == {"select": "containers"}


def test_cohort_query_full_to_json():
    q = CohortQuery(
        select="subjects",
        predicate=subject("birth_year", "gt", 1950),
        order_by=[("subjects.birth_year", True), "subjects.external_id"],
        limit=250,
        cursor="opaque",
    )
    assert q.to_json() == {
        "select":    "subjects",
        "predicate": {"subject_field": "birth_year", "op": "gt", "value": 1950},
        "order_by": [
            {"field": "subjects.birth_year", "descending": True},
            {"field": "subjects.external_id", "descending": False},
        ],
        "limit":  250,
        "cursor": "opaque",
    }


def test_cohort_query_default_limit_omitted():
    q = CohortQuery(select="containers", predicate=container("project", "eq", "a"))
    assert "limit" not in q.to_json()


def test_cohort_query_rejects_bad_select():
    with pytest.raises(ValueError, match="select must be"):
        CohortQuery(select="bogus")


def test_cohort_query_rejects_bad_limit():
    with pytest.raises(ValueError, match="limit"):
        CohortQuery(select="containers", limit=0)
    with pytest.raises(ValueError, match="limit"):
        CohortQuery(select="containers", limit=1001)


# ---------------------------------------------------- CohortResult

def test_cohort_result_from_json():
    r = CohortResult.from_json({
        "rows": [{"uri": "uri:tio:a"}, {"uri": "uri:tio:b"}],
        "next_cursor": "opaque",
        "select": "containers",
        "stats": {"rows_examined_estimate": 2},
    })
    assert len(r) == 2
    assert r.next_cursor == "opaque"
    assert r.select == "containers"
    assert list(r)[0]["uri"] == "uri:tio:a"


def test_cohort_result_terminal_page():
    r = CohortResult.from_json({"rows": [], "next_cursor": None,
                                  "select": "containers"})
    assert len(r) == 0
    assert r.next_cursor is None


# ---------------------------------------------------- cross-language anchor

def test_cross_language_predicate_json_literal():
    # The Java side asserts on the same literal string. This is the
    # W3 cross-language byte-equivalence anchor for predicates.
    p = (
        container("project", "eq", "alpha")
        & phenotype("diagnosis", "eq", "Alzheimer's")
    )
    wire = json.dumps(p.to_json(), separators=(",", ":"))
    assert wire == (
        '{"op":"and","children":'
        '[{"container_field":"project","op":"eq","value":"alpha"},'
        '{"phenotype":"diagnosis","op":"eq","value":"Alzheimer\'s"}]}'
    )
