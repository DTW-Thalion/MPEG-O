"""
ttio.workbench.pipeline -- pipeline submit client (W3 placeholder).

W3 ships `client.submit_pipeline(pipeline, inputs, params)`
posting `/v1/jobs` with the cohort-query inputs resolved at
submit time per the kickoff Decision-4 dual-column contract.
Returns a `Job` handle (see `ttio.workbench.jobs`).
"""

from __future__ import annotations

from ttio.workbench.cohort import _not_yet_implemented


class PipelineClient:
    """Pipeline registry + submit surface. **W3 placeholder.**"""

    def __init__(self, *args, **kwargs):
        _not_yet_implemented("PipelineClient", "W3")
