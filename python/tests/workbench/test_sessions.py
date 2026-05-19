"""
Unit tests for `ttio.workbench.sessions` and
`ttio.workbench.session_proxy`. Pure data; no daemon.
"""
from __future__ import annotations

import json

import pytest

from ttio.workbench.session_proxy import (
    SESSION_PROXY_SUBPROTOCOL,
    build_attach_handshake,
    session_proxy_url,
)
from ttio.workbench.sessions import (
    SESSION_STATUSES,
    TERMINAL_SESSION_STATUSES,
    Session,
    SessionsClient,
    validate_bind_mounts,
)


# ---------------------------------------------------- Session parsing

def test_session_from_json_minimal_starting():
    s = Session.from_json({
        "session_id":        "01HSESS",
        "status":            "starting",
        "project":           "alpha",
        "owner":             "alice",
        "engine_identifier": "shell",
        "started_at":        1700000000,
    })
    assert s.session_id == "01HSESS"
    assert s.status == "starting"
    assert s.host_port is None
    assert not s.is_terminal
    assert not s.is_attachable


def test_session_from_json_running_has_runtime_fields():
    s = Session.from_json({
        "session_id":        "01HSESS",
        "status":            "running",
        "project":           "alpha",
        "owner":             "alice",
        "engine_identifier": "shell",
        "started_at":        1700000000,
        "host_port":         18443,
        "pid":               12345,
        "container_id":      "shell-12345",
        "working_dir":       "/tmp/work",
        "ready_at":          1700000005,
        "last_seen_at":      1700000300,
        "command":           ["bash", "-l"],
        "env":               {"X": "y"},
        "bind_mounts":       {"/data": "/data"},
    })
    assert s.is_attachable
    assert not s.is_terminal
    assert s.host_port == 18443
    assert s.pid == 12345
    assert s.command == ("bash", "-l")


@pytest.mark.parametrize("status", ["terminated", "failed"])
def test_terminal_statuses(status):
    s = Session.from_json({
        "session_id": "01HSESS", "status": status,
        "project": "p", "owner": "u",
        "engine_identifier": "shell", "started_at": 0,
    })
    assert s.is_terminal
    assert not s.is_attachable


@pytest.mark.parametrize("status", ["starting", "running", "terminating"])
def test_non_terminal_statuses(status):
    s = Session.from_json({
        "session_id": "01HSESS", "status": status,
        "project": "p", "owner": "u",
        "engine_identifier": "shell", "started_at": 0,
    })
    assert not s.is_terminal


def test_only_running_is_attachable():
    for status in SESSION_STATUSES:
        s = Session.from_json({
            "session_id": "01HSESS", "status": status,
            "project": "p", "owner": "u",
            "engine_identifier": "shell", "started_at": 0,
        })
        assert s.is_attachable == (status == "running"), \
            f"unexpected attachable for {status}"


def test_session_statuses_constants():
    # Pin the wire-status set to catch drift if a server upgrade
    # adds a state.
    assert SESSION_STATUSES == {
        "starting", "running", "terminating", "terminated", "failed",
    }
    assert TERMINAL_SESSION_STATUSES == {"terminated", "failed"}


# ---------------------------------------------------- bind-mount validation

def test_validate_bind_mounts_happy_path():
    validate_bind_mounts(
        {"/var/lib/tti-workbench/containers/alpha/data": "/data"},
        project="alpha",
        container_storage_root="/var/lib/tti-workbench/containers",
    )


def test_validate_bind_mounts_relative_host_rejected():
    with pytest.raises(ValueError, match="absolute"):
        validate_bind_mounts({"data": "/data"}, project="alpha")


def test_validate_bind_mounts_traversal_rejected():
    with pytest.raises(ValueError, match=r"`\.\.`"):
        validate_bind_mounts(
            {"/var/lib/../etc": "/etc"}, project="alpha")


def test_validate_bind_mounts_relative_container_rejected():
    with pytest.raises(ValueError, match="container path must be absolute"):
        validate_bind_mounts({"/data": "data"}, project="alpha")


def test_validate_bind_mounts_outside_project_rejected():
    with pytest.raises(ValueError, match="must sit under"):
        validate_bind_mounts(
            {"/var/lib/tti-workbench/containers/beta/data": "/data"},
            project="alpha",
            container_storage_root="/var/lib/tti-workbench/containers",
        )


def test_validate_bind_mounts_empty_is_noop():
    validate_bind_mounts(None, project="alpha")
    validate_bind_mounts({}, project="alpha")


def test_validate_bind_mounts_without_storage_root_still_catches_typos():
    # When storage_root isn't known the client still catches absolute-
    # path + `..` typos. The server's project-scope rule fires later.
    with pytest.raises(ValueError, match="absolute"):
        validate_bind_mounts({"data": "/data"}, project="alpha")
    # But a plausible absolute path is accepted (server enforces).
    validate_bind_mounts({"/anywhere": "/data"}, project="alpha")


# ---------------------------------------------------- SessionsClient

def test_sessions_client_construction():
    c = SessionsClient(
        host="localhost", port=8443, scheme="http", token="ttiowbs_abc")
    assert c._host == "localhost"
    assert c._port == 8443


# ---------------------------------------------------- session_proxy helpers

def test_subprotocol_constant():
    assert SESSION_PROXY_SUBPROTOCOL == "ttio-session-proxy"


def test_session_proxy_url_default_scheme():
    assert session_proxy_url(host="h", port=8443, session_id="01H") \
        == "ws://h:8443/v1/sessions/01H/"


def test_session_proxy_url_wss():
    assert session_proxy_url(host="h", port=8443, session_id="01H",
                              scheme="wss") \
        == "wss://h:8443/v1/sessions/01H/"


def test_attach_handshake_default_path():
    hs = build_attach_handshake(token="ttiowbs_abc")
    assert hs == {"action": "attach", "token": "ttiowbs_abc", "path": "/"}


def test_attach_handshake_explicit_path():
    hs = build_attach_handshake(token="ttiowbs_abc", path="/api/kernels")
    assert hs["path"] == "/api/kernels"


def test_attach_handshake_prepends_slash():
    # Defensive prepend matches the server's behaviour
    # (Source/Sessions/TTIOWBSessionProxy.m:54-62).
    hs = build_attach_handshake(token="ttiowbs_abc", path="api/kernels")
    assert hs["path"] == "/api/kernels"


def test_attach_handshake_rejects_empty_token():
    with pytest.raises(ValueError, match="token"):
        build_attach_handshake(token="")


# ---------------------------------------------------- cross-language anchor

def test_cross_language_attach_handshake_literal():
    # Java's SessionProxy.buildAttachHandshake produces this exact
    # string. Drift in either client fails both suites.
    hs = build_attach_handshake(token="ttiowbs_abc", path="/api/kernels")
    wire = json.dumps(hs, separators=(",", ":"))
    assert wire == (
        '{"action":"attach",'
        '"token":"ttiowbs_abc",'
        '"path":"/api/kernels"}'
    )
