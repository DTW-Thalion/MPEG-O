"""
ttio.workbench.jobs -- job-tracking client (W3 placeholder).

W3 ships `Job.wait()`, `.status()`, `.cancel()`, `.events_sse()`
long-poll, `.output_container()` returning a `Container` for
result download. The SSE long-poll wraps a raw socket reader (the
v1.0 server's `/v1/jobs/{id}/events` emits raw bytes till close,
not chunked encoding) -- see
`tti-workbench-server/scripts/smoke_jobs.py` for the reference
parser.
"""

from __future__ import annotations

from ttio.workbench.cohort import _not_yet_implemented


class Job:
    """Pipeline-job handle. **W3 placeholder.**"""

    def __init__(self, *args, **kwargs):
        _not_yet_implemented("Job", "W3")


class JobsClient:
    """Jobs list / inspect surface. **W3 placeholder.**"""

    def __init__(self, *args, **kwargs):
        _not_yet_implemented("JobsClient", "W3")
