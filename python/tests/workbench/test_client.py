"""
Unit tests for the W2 SDK foundation: connect() factory, auth
providers, parse_filter_kv.
"""
from __future__ import annotations

import json
import os

import pytest

import ttio
from ttio.workbench import (
    BearerAuth,
    BootstrapAdminAuth,
    OIDCAuth,
    PasswordTotpAuth,
    Session,
    WorkbenchClient,
    connect,
    parse_filter_kv,
)
from ttio.workbench.client import _parse_url


# ---------------------------------------------------- top-level re-exports

def test_ttio_top_level_reexports():
    # Spec section 8.3's `ttio.connect(...)` and `ttio.OIDCAuth()`
    # must work without operators digging into sub-modules.
    assert ttio.connect is connect
    assert ttio.OIDCAuth is OIDCAuth
    assert ttio.PasswordTotpAuth is PasswordTotpAuth
    assert ttio.BearerAuth is BearerAuth
    assert ttio.BootstrapAdminAuth is BootstrapAdminAuth
    assert ttio.Session is Session
    assert ttio.WorkbenchClient is WorkbenchClient


# ---------------------------------------------------- URL parsing

def test_parse_url_wss():
    e = _parse_url("wss://biobank.example.com:8443/transport")
    assert e.host == "biobank.example.com"
    assert e.port == 8443
    assert e.ws_scheme == "wss"
    assert e.http_scheme == "https"


def test_parse_url_ws_default_port():
    e = _parse_url("ws://localhost/transport")
    assert e.host == "localhost"
    assert e.port == 8443  # default for workbench-server
    assert e.ws_scheme == "ws"
    assert e.http_scheme == "http"


def test_parse_url_https():
    e = _parse_url("https://workbench.internal:8443")
    assert e.ws_scheme == "wss"
    assert e.http_scheme == "https"


def test_parse_url_bare_host_port():
    e = _parse_url("localhost:8443")
    assert e.host == "localhost"
    assert e.port == 8443
    assert e.ws_scheme == "ws"


def test_parse_url_rejects_unknown_scheme():
    with pytest.raises(ValueError, match="unsupported scheme"):
        _parse_url("gopher://x")


def test_parse_url_rejects_missing_host():
    with pytest.raises(ValueError, match="missing host"):
        _parse_url("wss://:8443/transport")


# ---------------------------------------------------- auth providers

def test_password_totp_auth_carries_username():
    a = PasswordTotpAuth(username_="alice", password="pw", totp="012345")
    assert a.username == "alice"


def test_bearer_auth_synthesises_session():
    a = BearerAuth(
        token="ttiowbs_" + "x" * 43,
        username_="alice",
        projects=("alpha",),
        capabilities=frozenset({"containers.read.any_project"}))
    s = a.authenticate("h", 8443, "https")
    assert s.token == "ttiowbs_" + "x" * 43
    assert s.username == "alice"
    assert s.projects == ("alpha",)
    assert s.provider == "bearer"


def test_oidc_auth_raises_not_implemented():
    # `import ttio; ttio.OIDCAuth()` must be cheap (just stores the
    # config); calling .authenticate() / .username surfaces the
    # v1.1 deferral with a clear message.
    a = OIDCAuth(issuer="https://idp.example.com", client_id="x")
    with pytest.raises(NotImplementedError, match="v1.1 feature"):
        _ = a.username
    with pytest.raises(NotImplementedError, match="v1.1 feature"):
        a.authenticate("h", 8443, "https")


def test_bootstrap_admin_auth_reads_credentials_file(tmp_path):
    creds = {
        "username":          "admin",
        "password":          "pw",
        "totp_secret_base32": "JBSWY3DPEHPK3PXP",
    }
    creds_path = tmp_path / "bootstrap-credentials.json"
    creds_path.write_text(json.dumps(creds))
    a = BootstrapAdminAuth(staging_root=str(tmp_path))
    # `.username` must round-trip without a daemon call.
    assert a.username == "admin"


# ---------------------------------------------------- connect() factory

def test_connect_requires_auth():
    with pytest.raises(ValueError, match="requires.*auth"):
        connect("wss://localhost:8443/transport", auth=None)


def test_connect_calls_provider_authenticate(monkeypatch):
    captured = {}

    class _StubAuth:
        @property
        def username(self): return "alice"
        def authenticate(self, host, port, scheme):
            captured["host"] = host
            captured["port"] = port
            captured["scheme"] = scheme
            return Session(
                token="ttiowbs_" + "x" * 43,
                username="alice",
                user_id="U",
                capabilities=frozenset(),
                projects=(),
                expires_at=0,
                provider="stub",
                session_id="S",
            )

    client = connect("wss://biobank.example.com:8443/transport",
                      auth=_StubAuth())
    assert captured == {
        "host": "biobank.example.com",
        "port": 8443,
        "scheme": "https",  # https sibling of wss
    }
    assert isinstance(client, WorkbenchClient)
    assert client.session.username == "alice"
    assert client.host == "biobank.example.com"
    assert client.port == 8443
    assert client.ws_scheme == "wss"
    assert client.http_scheme == "https"


# ---------------------------------------------------- W3/W4/W5 sub-clients

def test_w3_w4_w5_sub_clients_are_live(monkeypatch):
    # W3 promoted client.query / pipelines / jobs; W4 promoted
    # sessions / session_proxy; W5.2 added containers. All five
    # sub-client factories are now live -- constructing them is
    # pure (no network). Calling .list() / .submit() /
    # .terminate() would hit the network and raise
    # WorkbenchHttpError on a closed port; out of scope for this
    # unit test.
    class _StubAuth:
        @property
        def username(self): return "alice"
        def authenticate(self, host, port, scheme):
            return Session(
                token="ttiowbs_" + "x" * 43, username="alice",
                user_id="U", capabilities=frozenset(), projects=(),
                expires_at=0, provider="stub", session_id="S")

    client = connect("ws://localhost:8443", auth=_StubAuth())
    assert client.containers() is not None
    assert client.jobs() is not None
    assert client.pipelines() is not None
    assert client.sessions() is not None
    # session_proxy builder is pure (no WS open until __aenter__).
    proxy = client.session_proxy("01HSESS")
    assert proxy is not None


# ---------------------------------------------------- filter parsing

def test_parse_filter_kv_basic():
    out = parse_filter_kv(["ms_level=1", "polarity=positive"])
    assert out == {"ms_level": 1, "polarity": "positive"}


def test_parse_filter_kv_floats():
    out = parse_filter_kv(["retention_time_min=12.5",
                           "retention_time_max=25.0"])
    assert out == {"retention_time_min": 12.5, "retention_time_max": 25.0}


def test_parse_filter_kv_strings():
    out = parse_filter_kv(["chromosome=chr6"])
    assert out == {"chromosome": "chr6"}


def test_parse_filter_kv_negative_integer():
    # Numeric coercion catches `-1` too -- relevant if a v1.1
    # filter expects sentinel ints.
    out = parse_filter_kv(["max_au=-1"])
    assert out == {"max_au": -1}


def test_parse_filter_kv_rejects_missing_eq():
    with pytest.raises(ValueError, match="expects k=v"):
        parse_filter_kv(["just_a_key"])


def test_parse_filter_kv_rejects_empty_key():
    with pytest.raises(ValueError, match="missing key"):
        parse_filter_kv(["=value"])


def test_parse_filter_kv_value_with_equals():
    # Equals signs inside the value are preserved (split on first
    # equals only).
    out = parse_filter_kv(["some_key=a=b=c"])
    assert out == {"some_key": "a=b=c"}
