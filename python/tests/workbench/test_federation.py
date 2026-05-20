"""W6.5 -- workbench federation client.

The key contract: a v1.0 single-node server (no /v1/federation/peers,
HTTP 404) yields an empty peer list, not an error. Other non-2xx
statuses still raise.
"""
from __future__ import annotations

import pytest

from ttio.workbench import federation
from ttio.workbench._http import WorkbenchHttpError
from ttio.workbench.federation import FederationClient, Peer


def _client():
    return FederationClient("localhost", 8443, scheme="http", token="t")


def _patch_http(monkeypatch, status, body):
    def fake_http_json(method, host, port, path, **kwargs):
        assert method == "GET"
        assert path == "/v1/federation/peers"
        return status, body
    monkeypatch.setattr(federation, "http_json", fake_http_json)


def test_v1_server_404_yields_empty_list(monkeypatch):
    _patch_http(monkeypatch, 404, {"error": "not found"})
    assert _client().peers() == []
    assert _client().is_federated() is False


def test_200_parses_peers(monkeypatch):
    _patch_http(monkeypatch, 200, {"peers": [
        {"peer_id": "node-a", "url": "wss://a.example:8443", "status": "online"},
        {"id": "node-b", "url": "wss://b.example:8443"},
    ]})
    peers = _client().peers()
    assert peers == [
        Peer("node-a", "wss://a.example:8443", "online"),
        Peer("node-b", "wss://b.example:8443", "unknown"),
    ]
    assert _client().is_federated() is True


def test_200_bare_list_body(monkeypatch):
    _patch_http(monkeypatch, 200,
                [{"peer_id": "n1", "url": "u1", "status": "online"}])
    assert _client().peers() == [Peer("n1", "u1", "online")]


def test_200_empty_is_not_federated(monkeypatch):
    _patch_http(monkeypatch, 200, {"peers": []})
    assert _client().peers() == []
    assert _client().is_federated() is False


def test_other_error_raises(monkeypatch):
    _patch_http(monkeypatch, 500, {"error": "boom"})
    with pytest.raises(WorkbenchHttpError):
        _client().peers()
