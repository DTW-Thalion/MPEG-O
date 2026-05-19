"""
Unit tests for `ttio.workbench.jobs` -- Job dataclass parsing,
JobEvent shape, JobsClient structural behaviour. Pure data; no
daemon.
"""
from __future__ import annotations

import pytest

from ttio.workbench.jobs import Job, JobEvent, JobsClient, build_cohort_input


# ---------------------------------------------------- Job parsing

def test_job_from_json_minimal():
    job = Job.from_json({
        "job_id":      "01HJOB",
        "pipeline_id": "01HPL",
        "status":      "queued",
        "project":     "alpha",
        "owner":       "alice",
        "queued_at":   1700000000,
    })
    assert job.job_id == "01HJOB"
    assert job.status == "queued"
    assert not job.is_terminal


def test_job_from_json_full():
    job = Job.from_json({
        "job_id":            "01HJOB",
        "pipeline_id":       "01HPL",
        "status":            "completed",
        "project":           "alpha",
        "owner":             "alice",
        "queued_at":         1700000000,
        "started_at":        1700000010,
        "completed_at":      1700000100,
        "working_dir":       "/tmp/work",
        "engine_identifier": "shell",
        "pid":               12345,
        "exit_code":         0,
        "inputs":            {"raw_reads": "uri:tio:r1"},
        "params":            {"threads": 4},
        "inputs_query":      {"raw_reads": {"cohort_query": {"select": "containers"}}},
    })
    assert job.status == "completed"
    assert job.is_terminal
    assert job.engine_identifier == "shell"
    assert job.pid == 12345
    assert job.exit_code == 0
    assert job.inputs["raw_reads"] == "uri:tio:r1"
    assert job.inputs_query["raw_reads"]["cohort_query"]["select"] == "containers"


@pytest.mark.parametrize("status", ["completed", "failed", "cancelled"])
def test_terminal_statuses(status):
    job = Job.from_json({
        "job_id": "j", "pipeline_id": "p", "status": status,
        "project": "x", "owner": "y", "queued_at": 0,
    })
    assert job.is_terminal


@pytest.mark.parametrize("status", ["queued", "starting", "running"])
def test_non_terminal_statuses(status):
    job = Job.from_json({
        "job_id": "j", "pipeline_id": "p", "status": status,
        "project": "x", "owner": "y", "queued_at": 0,
    })
    assert not job.is_terminal


def test_optional_fields_default_to_none():
    job = Job.from_json({
        "job_id": "j", "pipeline_id": "p", "status": "running",
        "project": "x", "owner": "y", "queued_at": 0,
    })
    assert job.started_at is None
    assert job.completed_at is None
    assert job.pid is None
    assert job.exit_code is None
    assert job.error_message is None
    assert job.inputs == {}


# ---------------------------------------------------- JobEvent

def test_job_event_construction():
    ev = JobEvent(event="job.state", data={"status": "running"})
    assert ev.event == "job.state"
    assert ev.data["status"] == "running"


def test_job_event_empty_data():
    ev = JobEvent(event="", data={})
    assert ev.event == ""
    assert ev.data == {}


# ---------------------------------------------------- cohort-input envelope

def test_build_cohort_input():
    env = build_cohort_input({"select": "containers", "predicate": {"x": 1}})
    assert env == {"cohort_query": {"select": "containers",
                                       "predicate": {"x": 1}}}


# ---------------------------------------------------- JobsClient structure

def test_jobs_client_construction():
    # Pure construction; no daemon round-trip.
    client = JobsClient(host="localhost", port=8443,
                        scheme="http", token="ttiowbs_abc")
    # Spot-check attribute capture.
    assert client._host == "localhost"
    assert client._port == 8443
    assert client._scheme == "http"
    assert client._token == "ttiowbs_abc"
