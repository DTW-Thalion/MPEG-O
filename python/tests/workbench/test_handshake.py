"""
Unit tests for the workbench-transport handshake JSON builders.

Pure-data tests; no daemon, no WS, no I/O. The Java port's
equivalent test asserts byte-identical output for the same
inputs.
"""
from __future__ import annotations

import json

import pytest

from ttio.workbench.transport.handshake import (
    ALLOWED_DOWNLOAD_FILTER_KEYS,
    OutputModeLiteral,
    ServerFrameKind,
    WS_SUBPROTOCOL,
    build_download_handshake,
    build_upload_handshake,
    parse_server_frame,
)


# ---------------------------------------------------- subprotocol constant

def test_ws_subprotocol_matches_server():
    # Daemon's libwebsockets mount at /transport requires this
    # exact string in Sec-WebSocket-Protocol. Pinning it here
    # catches drift via a search in the tests rather than a
    # silent CI fail.
    assert WS_SUBPROTOCOL == "ttio-transport"


# ---------------------------------------------------- upload handshake

def test_build_upload_handshake_minimal():
    out = build_upload_handshake(
        owner="alice", project="alpha", container_uri="uri:tio:demo-001")
    assert out == {
        "type":          "handshake",
        "owner":         "alice",
        "project":       "alpha",
        "container_uri": "uri:tio:demo-001",
    }


def test_build_upload_handshake_with_token():
    out = build_upload_handshake(
        owner="alice", project="alpha",
        container_uri="uri:tio:demo-001",
        token="ttiowbs_abc")
    assert out["token"] == "ttiowbs_abc"


def test_build_upload_handshake_with_resume():
    out = build_upload_handshake(
        owner="alice", project="alpha",
        container_uri="uri:tio:demo-001",
        token="ttiowbs_abc",
        resume_handle="stg-deadbeef")
    assert out["resume_handle"] == "stg-deadbeef"


@pytest.mark.parametrize("missing", ["owner", "project", "container_uri"])
def test_build_upload_handshake_rejects_missing(missing):
    kwargs = {"owner": "alice", "project": "alpha",
              "container_uri": "uri:tio:demo-001"}
    kwargs[missing] = ""
    with pytest.raises(ValueError, match=missing):
        build_upload_handshake(**kwargs)


# ---------------------------------------------------- download handshake

def test_build_download_handshake_minimal():
    out = build_download_handshake(container_uri="uri:tio:demo-001")
    assert out == {
        "type":          "handshake",
        "mode":          "download",
        "container_uri": "uri:tio:demo-001",
        "output_mode":   "binary",
    }


def test_build_download_handshake_with_filter():
    out = build_download_handshake(
        container_uri="uri:tio:demo-001",
        filter={"ms_level": 1, "retention_time_min": 12.5})
    assert out["filter"] == {"ms_level": 1, "retention_time_min": 12.5}


def test_build_download_handshake_rejects_unknown_filter_key():
    with pytest.raises(ValueError, match="unknown filter key"):
        build_download_handshake(
            container_uri="uri:tio:demo-001",
            filter={"not_a_real_key": 1})


def test_build_download_handshake_rejects_bad_output_mode():
    with pytest.raises(ValueError, match="output_mode must be"):
        build_download_handshake(
            container_uri="uri:tio:demo-001",
            output_mode="not-a-mode")


def test_build_download_handshake_includes_max_au_when_positive():
    out = build_download_handshake(
        container_uri="uri:tio:demo-001", max_au=100)
    assert out["max_au"] == 100


def test_build_download_handshake_omits_max_au_when_zero():
    out = build_download_handshake(container_uri="uri:tio:demo-001", max_au=0)
    assert "max_au" not in out


def test_build_download_handshake_rejects_negative_max_au():
    with pytest.raises(ValueError, match="max_au must be"):
        build_download_handshake(container_uri="uri:tio:demo-001", max_au=-1)


def test_allowed_filter_keys_match_server():
    # Pinning the set of filter keys catches drift if a server-side
    # change removes a supported predicate without updating the
    # client's accept list (would result in 1011 close at run time).
    expected = {
        "ms_level", "polarity",
        "retention_time_min", "retention_time_max",
        "precursor_mz_min", "precursor_mz_max",
        "precursor_charge", "max_au",
    }
    assert ALLOWED_DOWNLOAD_FILTER_KEYS == expected


# ---------------------------------------------------- frame parser

def test_parse_ack_frame():
    kind, body = parse_server_frame('{"type":"ack","au_sequence":12}')
    assert kind is ServerFrameKind.ACK
    assert body["au_sequence"] == 12


def test_parse_done_frame():
    kind, body = parse_server_frame(
        '{"type":"done","container_uri":"uri:tio:demo-001"}')
    assert kind is ServerFrameKind.DONE
    assert body["container_uri"] == "uri:tio:demo-001"


def test_parse_error_frame():
    kind, body = parse_server_frame(
        '{"type":"error","message":"bad handshake"}')
    assert kind is ServerFrameKind.ERROR
    assert body["message"] == "bad handshake"


def test_parse_unknown_frame_kind_raises():
    with pytest.raises(ValueError, match="unknown server frame type"):
        parse_server_frame('{"type":"weird"}')


def test_parse_non_json_raises():
    with pytest.raises(ValueError, match="server frame not JSON"):
        parse_server_frame("not json")


def test_parse_non_object_raises():
    with pytest.raises(ValueError, match="server frame not an object"):
        parse_server_frame('[]')


def test_parse_accepts_bytes():
    kind, _ = parse_server_frame(b'{"type":"ack"}')
    assert kind is ServerFrameKind.ACK


# ---------------------------------------------------- output mode literal

def test_output_mode_values():
    assert OutputModeLiteral.BINARY.value == "binary"
    assert OutputModeLiteral.STATS_ONLY.value == "stats-only"
    assert OutputModeLiteral.STATS_WITH_PAYLOAD.value == "stats-with-payload"
