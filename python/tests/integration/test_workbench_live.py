"""
Live-daemon end-to-end integration test for the workbench client SDK.

Drives the real `ttio.workbench.*` client surface (W1-W5) against a
running `tti-workbench-server` daemon. This is the live half of the
W1-W5 acceptance gates -- the unit suites pin the wire shapes; this
test proves the client actually talks to the daemon.

GATING: the whole module SKIPS unless the daemon-coordinate env vars
are set, so it never runs (or fails) in the normal unit-test CI:

    TTIO_WORKBENCH_URL       ws://127.0.0.1:<port>/transport
    TTIO_WORKBENCH_STAGING   <staging-root containing bootstrap-credentials.json>
    TTIO_WORKBENCH_PROJECT   project the bootstrap admin is a member of (default "adni")

The local runner `scripts/workbench-live-smoke.sh` boots the daemon,
seeds the admin's project, exports these, and invokes pytest; the
`workbench-live` CI workflow does the same on a built server.

Flow exercised:
  - connect via BootstrapAdminAuth (W1 auth)
  - containers().list() (W5.2 / SDK containers)
  - pipelines().register() + list() + get() (W3)
  - jobs().submit() + poll to terminal + cancel a second job (W3)
  - jobs().events() SSE long-poll to a terminal frame (W3)
  - cohort preview_count() (W3)
  - sessions().create() + list() + terminate() (W4)
"""
from __future__ import annotations

import asyncio
import os
import time
import uuid

import pytest

URL = os.environ.get("TTIO_WORKBENCH_URL")
STAGING = os.environ.get("TTIO_WORKBENCH_STAGING")
PROJECT = os.environ.get("TTIO_WORKBENCH_PROJECT", "adni")

pytestmark = pytest.mark.skipif(
    not (URL and STAGING),
    reason="live workbench daemon env not set "
           "(TTIO_WORKBENCH_URL + TTIO_WORKBENCH_STAGING)",
)


@pytest.fixture(scope="module")
def client():
    import ttio
    from ttio.workbench.auth_providers import BootstrapAdminAuth
    c = ttio.connect(URL, auth=BootstrapAdminAuth(staging_root=STAGING))
    return c


# ---------------------------------------------------- W1 auth

def test_connect_as_bootstrap_admin(client):
    assert client.session.username == "admin"
    assert client.session.token.startswith("ttiowbs_")


# ---------------------------------------------------- W5.2 containers

def test_containers_list_round_trips(client):
    page = client.containers().list(project=PROJECT)
    # Fresh daemon: list is reachable + well-formed (may be empty).
    assert isinstance(page.containers, list)


# ---------------------------------------------------- W3 cohort

def test_cohort_preview_count_round_trips(client):
    # The cohort REST plane (POST /v1/cohorts/preview-count) was
    # 404 in workbench-server v1.0 -- TTIOWBCohortsHandler was
    # implemented but never registered on the router. Fixed in
    # tti-workbench-server PR #29 (handler registered at
    # shared-service init); this test exercises it normally now.
    from ttio.workbench.cohort import CohortQuery, container
    query = CohortQuery(
        select="containers",
        predicate=container("project", "eq", PROJECT),
    )
    count = client.preview_count(query)
    assert isinstance(count, int)
    assert count >= 0


# ---------------------------------------------------- W3 pipelines + jobs

@pytest.fixture(scope="module")
def echo_pipeline_id(client):
    pl = client.pipelines().register(
        identifier="live-smoke-echo-" + uuid.uuid4().hex[:8],
        version="1.0.0",
        project=PROJECT,
        engine_pin="shell",
        definition="echo live-smoke-output && sleep 0.1",
        inputs_schema={},
        outputs_schema={},
    )
    assert pl.pipeline_id
    return pl.pipeline_id


def test_pipeline_register_then_listed(client, echo_pipeline_id):
    listed = {p.pipeline_id for p in client.pipelines().list()}
    assert echo_pipeline_id in listed
    fetched = client.pipelines().get(echo_pipeline_id)
    assert fetched.pipeline_id == echo_pipeline_id


def test_job_submit_runs_to_completion(client, echo_pipeline_id):
    job = client.jobs().submit(
        pipeline_id=echo_pipeline_id, inputs={}, params={})
    assert job.job_id
    deadline = time.time() + 30
    last = job
    while time.time() < deadline:
        last = client.jobs().get(job.job_id)
        if last.is_terminal:
            break
        time.sleep(0.2)
    assert last.is_terminal, f"job never terminated; last status={last.status}"
    assert last.status == "completed", f"unexpected terminal status {last.status}"


def test_job_events_stream_reaches_terminal(client, echo_pipeline_id):
    job = client.jobs().submit(
        pipeline_id=echo_pipeline_id, inputs={}, params={})

    async def collect():
        seen = []
        jobs = client.jobs()
        async for ev in jobs.events(job.job_id):
            seen.append(ev)
            status = ev.data.get("status")
            if status in ("completed", "failed", "cancelled"):
                break
            if len(seen) > 200:
                break
        return seen

    events = asyncio.run(asyncio.wait_for(collect(), timeout=30))
    assert events, "no SSE frames received"
    statuses = [e.data.get("status") for e in events if e.event == "job.state"]
    assert "completed" in statuses, f"terminal not seen; statuses={statuses}"


def test_job_cancel(client, echo_pipeline_id):
    # A slow pipeline so we can cancel before it finishes.
    slow = client.pipelines().register(
        identifier="live-smoke-slow-" + uuid.uuid4().hex[:8],
        version="1.0.0",
        project=PROJECT,
        engine_pin="shell",
        definition="sleep 60",
        inputs_schema={},
        outputs_schema={},
    )
    job = client.jobs().submit(pipeline_id=slow.pipeline_id, inputs={}, params={})
    # Wait until it leaves the queue, then cancel.
    deadline = time.time() + 15
    while time.time() < deadline:
        cur = client.jobs().get(job.job_id)
        if cur.status in ("starting", "running", "queued"):
            break
        time.sleep(0.2)
    client.jobs().cancel(job.job_id)
    deadline = time.time() + 15
    last = None
    while time.time() < deadline:
        last = client.jobs().get(job.job_id)
        if last.is_terminal:
            break
        time.sleep(0.2)
    assert last is not None and last.status == "cancelled", \
        f"expected cancelled; got {None if last is None else last.status}"


# ---------------------------------------------------- W4 sessions

def test_session_create_list_terminate(client):
    sessions = client.sessions()
    created = sessions.create(
        project=PROJECT,
        engine_pin="shell",
        command=["/bin/sh", "-c", "sleep 60"],
    )
    assert created.session_id
    try:
        listed = {s.session_id for s in sessions.list(limit=100)}
        assert created.session_id in listed
    finally:
        sessions.terminate(created.session_id)
    deadline = time.time() + 15
    last = None
    while time.time() < deadline:
        last = sessions.get(created.session_id)
        if last.is_terminal:
            break
        time.sleep(0.2)
    assert last is not None and last.is_terminal, \
        f"session never terminated; status={None if last is None else last.status}"
