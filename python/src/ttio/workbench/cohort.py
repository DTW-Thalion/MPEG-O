"""
ttio.workbench.cohort -- cohort query client surface (W3 placeholder).

W3 ships the real implementation: `client.query(predicate, ...)`
builds a JSON cohort-query AST mirroring the server's
`TTIOWBCohortQuery`, POSTs `/v1/cohorts/query`, and returns a
`CohortResult` with `.subjects`, `.containers`, `.layers(...)`,
`.save(name)`.

W2 ships this stub so the namespace is reserved and SDK callers
get a clear "W3" error rather than `AttributeError`.
"""

from __future__ import annotations


def _not_yet_implemented(symbol: str, milestone: str) -> None:
    """Raise the canonical "feature lands in milestone X" error.

    Shared by the cohort + pipeline + jobs + sessions stubs so the
    message reads consistently regardless of which surface the
    caller hit. Keeps the v1.0 SDK importable while signalling
    clear expectations.
    """
    raise NotImplementedError(
        f"{symbol} is a {milestone} feature; the v1.0 workbench "
        f"client (W1 + W2) only ships auth + transport (upload + "
        f"download + filtered streaming). See "
        f"docs/workbench-client-workplan.md for the milestone plan.")


class CohortQuery:
    """Cohort query builder. **W3 surface** -- placeholder today."""

    def __init__(self, *args, **kwargs):
        _not_yet_implemented("CohortQuery", "W3")


class CohortResult:
    """Cohort query result. **W3 surface** -- placeholder today."""

    def __init__(self, *args, **kwargs):
        _not_yet_implemented("CohortResult", "W3")
