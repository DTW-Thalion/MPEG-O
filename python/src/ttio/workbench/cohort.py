"""
ttio.workbench.cohort -- cohort query client surface.

Builds a JSON predicate tree that round-trips through the workbench
server's `POST /v1/cohorts/query` and `POST /v1/cohorts/preview-count`
endpoints (server-side: `TTIOWBCohortQuery` + `TTIOWBCohortService`).

Wire shape per the v1.0 wire-contract survey (see
`docs/workbench-client/W3-progress.md`):

  {
    "select":    "containers" | "subjects" | "samples",
    "predicate": <predicate-tree>,            # optional
    "order_by":  [{"field":"<table>.<col>","descending":bool}, ...],  # optional
    "limit":     <int 1..1000>,               # optional, default 100
    "cursor":    "<opaque base64 from prior response>",   # optional
  }

Predicate leaves (4 kinds; allow-listed fields in each):

  {"container_field": "<col>", "op": "<op>", "value": <v>}
  {"subject_field":   "<col>", "op": "<op>", "value": <v>}
  {"sample_field":    "<col>", "op": "<op>", "value": <v>}
  {"phenotype":       "<name>", "op": "<op>", "value": <v>}

Composites:

  {"op": "and", "children": [<pred>, ...]}
  {"op": "or",  "children": [<pred>, ...]}        -- phenotype leaves rejected
  {"op": "not", "child":     <pred>}              -- phenotype leaves rejected

Operators: eq, ne, lt, gt, le, ge, in (value=array), like (string only),
exists (no value).

v1.0 server does NOT expose:
  - `GET /v1/cohorts` / `POST /v1/cohorts` (saved cohorts) -- ephemeral
    queries only.
  - `has_layer(...)` assay-availability filters.
  - Cohort-membership filters as a separate leaf kind.

Future v1.x server upgrades may add these; the client is forward-
compatible because predicate composition is purely additive.
"""

from __future__ import annotations

import dataclasses
from typing import Any, Iterable, Mapping, Optional, Sequence, Union


# Allow-listed leaf fields per the server's TTIOWBCohortQuery.h.
ALLOWED_CONTAINER_FIELDS = frozenset({
    "project", "owner", "encrypted",
    "created_at", "updated_at", "uri",
})
ALLOWED_SUBJECT_FIELDS = frozenset({
    "project", "external_id", "sex", "birth_year",
})
ALLOWED_SAMPLE_FIELDS = frozenset({
    "sample_kind", "collected_at",
})

ALLOWED_OPS = frozenset({
    "eq", "ne", "lt", "gt", "le", "ge", "in", "like", "exists",
})

ALLOWED_SELECT = frozenset({"containers", "subjects", "samples"})


def _not_yet_implemented(symbol: str, milestone: str) -> None:
    """Shared "available in milestone X" raiser.

    W3 promotes the cohort + pipeline + jobs surfaces; sessions
    (W4) still uses this helper.
    """
    raise NotImplementedError(
        f"{symbol} is a {milestone} feature; the v1.0 workbench "
        f"client (W1 + W2 + W3) ships auth + transport + CLI + SDK + "
        f"cohort + pipeline + jobs. See "
        f"docs/workbench-client-workplan.md for the milestone plan.")


# ----------------------------------------------------------------
# Predicate AST
# ----------------------------------------------------------------

class CohortPredicate:
    """Abstract base for cohort-query predicate nodes.

    Pure data; no I/O. Subclasses (`ContainerFieldPredicate`,
    `SubjectFieldPredicate`, `SampleFieldPredicate`,
    `PhenotypePredicate`, `AndPredicate`, `OrPredicate`,
    `NotPredicate`) each know how to serialise themselves to the
    server's JSON shape via `to_json()`.
    """

    def to_json(self) -> dict[str, Any]:
        """Serialise the predicate to the server's JSON shape.

        Returns
        -------
        dict[str, Any]
            JSON-ready dict matching the wire contract documented
            at the top of this module.

        Raises
        ------
        NotImplementedError
            Subclasses must override; the abstract base never
            serialises directly.
        """
        raise NotImplementedError

    def __and__(self, other: "CohortPredicate") -> "AndPredicate":
        """Compose two predicates as an AND.

        Parameters
        ----------
        other : CohortPredicate
            Right-hand predicate.

        Returns
        -------
        AndPredicate
            New conjunction. When the left side is already an AND
            the children are flattened in-place.
        """
        if isinstance(self, AndPredicate):
            return AndPredicate([*self.children, other])
        return AndPredicate([self, other])

    def __or__(self, other: "CohortPredicate") -> "OrPredicate":
        """Compose two predicates as an OR.

        Parameters
        ----------
        other : CohortPredicate
            Right-hand predicate.

        Returns
        -------
        OrPredicate
            New disjunction. When the left side is already an OR
            the children are flattened in-place. Phenotype leaves
            on either side trigger a ``ValueError`` (the server
            rejects phenotype-under-OR with 422).
        """
        if isinstance(self, OrPredicate):
            return OrPredicate([*self.children, other])
        return OrPredicate([self, other])

    def __invert__(self) -> "NotPredicate":
        """Wrap the predicate in a logical NOT.

        Returns
        -------
        NotPredicate
            New negation. Phenotype leaves under NOT raise
            ``ValueError`` (the server rejects with 422).
        """
        return NotPredicate(self)


def _validate_op(op: str) -> str:
    if op not in ALLOWED_OPS:
        raise ValueError(
            f"unknown predicate op {op!r}; allowed: {sorted(ALLOWED_OPS)}")
    return op


def _validate_field(field: str, allowed: frozenset[str], kind: str) -> str:
    if field not in allowed:
        raise ValueError(
            f"unknown {kind} field {field!r}; allowed: {sorted(allowed)}")
    return field


@dataclasses.dataclass(frozen=True)
class ContainerFieldPredicate(CohortPredicate):
    field: str
    op: str
    value: Any = None

    def __post_init__(self):
        _validate_field(self.field, ALLOWED_CONTAINER_FIELDS, "container")
        _validate_op(self.op)

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"container_field": self.field, "op": self.op}
        if self.op != "exists":
            out["value"] = self.value
        return out


@dataclasses.dataclass(frozen=True)
class SubjectFieldPredicate(CohortPredicate):
    field: str
    op: str
    value: Any = None

    def __post_init__(self):
        _validate_field(self.field, ALLOWED_SUBJECT_FIELDS, "subject")
        _validate_op(self.op)

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"subject_field": self.field, "op": self.op}
        if self.op != "exists":
            out["value"] = self.value
        return out


@dataclasses.dataclass(frozen=True)
class SampleFieldPredicate(CohortPredicate):
    field: str
    op: str
    value: Any = None

    def __post_init__(self):
        _validate_field(self.field, ALLOWED_SAMPLE_FIELDS, "sample")
        _validate_op(self.op)

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"sample_field": self.field, "op": self.op}
        if self.op != "exists":
            out["value"] = self.value
        return out


@dataclasses.dataclass(frozen=True)
class PhenotypePredicate(CohortPredicate):
    """Phenotype-keyed leaf. Server-side joins to
    `subject_phenotypes` table. **Cannot appear under `or` / `not`
    composites** -- the server rejects with 422 (the column join
    can't reason about NULL the same way as a structural field).
    """

    name: str
    op: str
    value: Any = None

    def __post_init__(self):
        if not self.name:
            raise ValueError("phenotype predicate requires a `name`")
        _validate_op(self.op)

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"phenotype": self.name, "op": self.op}
        if self.op != "exists":
            out["value"] = self.value
        return out


def _contains_phenotype(p: CohortPredicate) -> bool:
    if isinstance(p, PhenotypePredicate):
        return True
    if isinstance(p, (AndPredicate, OrPredicate)):
        return any(_contains_phenotype(c) for c in p.children)
    if isinstance(p, NotPredicate):
        return _contains_phenotype(p.child)
    return False


@dataclasses.dataclass(frozen=True)
class AndPredicate(CohortPredicate):
    children: Sequence[CohortPredicate]

    def __post_init__(self):
        if not self.children:
            raise ValueError("AND requires at least one child")

    def to_json(self) -> dict[str, Any]:
        return {"op": "and", "children": [c.to_json() for c in self.children]}


@dataclasses.dataclass(frozen=True)
class OrPredicate(CohortPredicate):
    children: Sequence[CohortPredicate]

    def __post_init__(self):
        if not self.children:
            raise ValueError("OR requires at least one child")
        for c in self.children:
            if _contains_phenotype(c):
                raise ValueError(
                    "phenotype leaves cannot appear under OR (server "
                    "rejects with 422 -- column joins can't reason "
                    "about NULL the same way as structural fields)")

    def to_json(self) -> dict[str, Any]:
        return {"op": "or", "children": [c.to_json() for c in self.children]}


@dataclasses.dataclass(frozen=True)
class NotPredicate(CohortPredicate):
    child: CohortPredicate

    def __post_init__(self):
        if _contains_phenotype(self.child):
            raise ValueError(
                "phenotype leaves cannot appear under NOT")

    def to_json(self) -> dict[str, Any]:
        return {"op": "not", "child": self.child.to_json()}


# Convenience constructors. The factory functions make
# call sites read like the spec's section 8.3 sample
# (`subject("birth_year", "gt", 1950)`).

def container(field: str, op: str = "eq", value: Any = None) -> ContainerFieldPredicate:
    """Construct a container-field predicate leaf.

    Parameters
    ----------
    field : str
        One of the allow-listed container columns
        (see :data:`ALLOWED_CONTAINER_FIELDS`).
    op : str, optional
        Comparison operator. Default ``"eq"``.
    value : Any, optional
        Right-hand value. Omitted when ``op == "exists"``.

    Returns
    -------
    ContainerFieldPredicate
        Validated leaf node.
    """
    return ContainerFieldPredicate(field=field, op=op, value=value)

def subject(field: str, op: str = "eq", value: Any = None) -> SubjectFieldPredicate:
    """Construct a subject-field predicate leaf.

    Parameters
    ----------
    field : str
        One of the allow-listed subject columns
        (see :data:`ALLOWED_SUBJECT_FIELDS`).
    op : str, optional
        Comparison operator. Default ``"eq"``.
    value : Any, optional
        Right-hand value. Omitted when ``op == "exists"``.

    Returns
    -------
    SubjectFieldPredicate
        Validated leaf node.
    """
    return SubjectFieldPredicate(field=field, op=op, value=value)

def sample(field: str, op: str = "eq", value: Any = None) -> SampleFieldPredicate:
    """Construct a sample-field predicate leaf.

    Parameters
    ----------
    field : str
        One of the allow-listed sample columns
        (see :data:`ALLOWED_SAMPLE_FIELDS`).
    op : str, optional
        Comparison operator. Default ``"eq"``.
    value : Any, optional
        Right-hand value. Omitted when ``op == "exists"``.

    Returns
    -------
    SampleFieldPredicate
        Validated leaf node.
    """
    return SampleFieldPredicate(field=field, op=op, value=value)

def phenotype(name: str, op: str = "eq", value: Any = None) -> PhenotypePredicate:
    """Construct a phenotype-keyed predicate leaf.

    Parameters
    ----------
    name : str
        Phenotype name; joined server-side to the
        ``subject_phenotypes`` table.
    op : str, optional
        Comparison operator. Default ``"eq"``.
    value : Any, optional
        Right-hand value. Omitted when ``op == "exists"``.

    Returns
    -------
    PhenotypePredicate
        Validated leaf node. Cannot appear under ``or`` / ``not``
        composites.
    """
    return PhenotypePredicate(name=name, op=op, value=value)


# ----------------------------------------------------------------
# CohortQuery (full request) + CohortResult (full response)
# ----------------------------------------------------------------

OrderBy = Union[str, tuple[str, bool]]
"""Order-by clause: either a bare `"table.column"` (ascending) or a
2-tuple `("table.column", descending: bool)`."""


@dataclasses.dataclass(frozen=True)
class CohortQuery:
    """Full request body for `POST /v1/cohorts/query` and
    `POST /v1/cohorts/preview-count`.

    Args:
        select: `"containers"`, `"subjects"`, or `"samples"`.
        predicate: optional `CohortPredicate` tree.
        order_by: optional list of order-by clauses. Each is either
            `"table.column"` (asc) or `("table.column", True)`
            (desc).
        limit: result row cap. Server max is 1000; default 100.
        cursor: opaque base64url cursor from a prior response's
            `next_cursor` field.
    """

    select: str = "containers"
    predicate: Optional[CohortPredicate] = None
    order_by: Sequence[OrderBy] = ()
    limit: int = 100
    cursor: Optional[str] = None

    def __post_init__(self):
        if self.select not in ALLOWED_SELECT:
            raise ValueError(
                f"select must be one of {sorted(ALLOWED_SELECT)}; "
                f"got {self.select!r}")
        if self.limit < 1 or self.limit > 1000:
            raise ValueError(
                f"limit must be in [1, 1000]; got {self.limit}")

    def to_json(self) -> dict[str, Any]:
        """Serialise the query to the server's JSON request shape.

        Returns
        -------
        dict[str, Any]
            JSON-ready dict matching ``POST /v1/cohorts/query`` and
            ``POST /v1/cohorts/preview-count``. Omits ``limit`` when
            it equals the default (100) so the wire bytes stay
            compact.
        """
        out: dict[str, Any] = {"select": self.select}
        if self.predicate is not None:
            out["predicate"] = self.predicate.to_json()
        if self.order_by:
            out["order_by"] = [_order_by_to_json(c) for c in self.order_by]
        if self.limit != 100:
            out["limit"] = self.limit
        if self.cursor is not None:
            out["cursor"] = self.cursor
        return out


def _order_by_to_json(clause: OrderBy) -> dict[str, Any]:
    if isinstance(clause, str):
        return {"field": clause, "descending": False}
    field, desc = clause
    return {"field": field, "descending": bool(desc)}


@dataclasses.dataclass(frozen=True)
class CohortResult:
    """Parsed `POST /v1/cohorts/query` response.

    Args:
        rows: result rows as dicts; shape varies by `select`.
        next_cursor: opaque cursor for the next page; None on the
            final page.
        select: echoed select value.
        stats: optional server-side stats dict (`rows_examined_estimate`
            etc.). Present in some v1 responses.
    """

    rows: tuple[Mapping[str, Any], ...]
    next_cursor: Optional[str]
    select: str
    stats: Mapping[str, Any] = dataclasses.field(default_factory=dict)

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "CohortResult":
        """Build a :class:`CohortResult` from a parsed JSON body.

        Parameters
        ----------
        body : Mapping[str, Any]
            Decoded JSON object from ``POST /v1/cohorts/query``.

        Returns
        -------
        CohortResult
            Rows + optional ``next_cursor`` + echoed select.
        """
        return cls(
            rows=tuple(body.get("rows", [])),
            next_cursor=body.get("next_cursor"),
            select=body.get("select", "containers"),
            stats=body.get("stats", {}),
        )

    def __iter__(self) -> Iterable[Mapping[str, Any]]:
        """Iterate over result rows in their wire order.

        Returns
        -------
        Iterable[Mapping[str, Any]]
            Iterator over the parsed row dicts.
        """
        return iter(self.rows)

    def __len__(self) -> int:
        """Return the number of rows on this page.

        Returns
        -------
        int
            Row count. Does not include rows on subsequent pages.
        """
        return len(self.rows)
