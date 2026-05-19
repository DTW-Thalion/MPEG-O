"""
Unit tests for `ttio.workbench.auth`.

No daemon required: TOTP is pure math, Session is a dataclass,
login_password is tested against a stub urlopen.
"""
from __future__ import annotations

import io
import json
import urllib.error
import urllib.request

import pytest

from ttio.workbench.auth import (
    AccountDisabled,
    InvalidCredentials,
    RateLimitExceeded,
    Session,
    WorkbenchAuthError,
    current_totp,
    login_password,
)


# ---------------------------------------------------------------- TOTP

def test_current_totp_deterministic_vector():
    # Determinism + cross-language fixture: the same secret +
    # epoch must produce the same six-digit code regardless of which
    # client computes it. The Java test asserts the same pair.
    secret_b32 = "JBSWY3DPEHPK3PXP"  # base32("Hello!\xde\xad\xbe\xef")
    assert current_totp(secret_b32, t=1234567890.0) == "742275"
    assert current_totp(secret_b32, t=1700000000.0) == "324550"


def test_current_totp_changes_per_step():
    secret = "JBSWY3DPEHPK3PXP"
    code_a = current_totp(secret, t=1700000000.0)        # step N
    code_b = current_totp(secret, t=1700000000.0 + 30.0) # step N+1
    assert code_a != code_b


def test_current_totp_is_six_digits():
    secret = "JBSWY3DPEHPK3PXP"
    code = current_totp(secret, t=1700000000.0)
    assert len(code) == 6
    assert code.isdigit()


# -------------------------------------------------------------- Session

def test_session_basics():
    s = Session(
        token="ttiowbs_abc",
        username="alice",
        user_id="01HXY",
        capabilities=frozenset({"containers.read.any_project"}),
        projects=("alpha", "beta"),
        expires_at=2_000_000_000,
        provider="password-totp",
        session_id="01SES",
    )
    assert s.authorization_header() == "Bearer ttiowbs_abc"
    assert s.has_capability("containers.read.any_project")
    assert not s.has_capability("sessions.start")
    assert not s.expired


def test_session_expired():
    s = Session(
        token="ttiowbs_abc",
        username="alice",
        user_id="01HXY",
        capabilities=frozenset(),
        projects=(),
        expires_at=0,  # 1970-01-01
        provider="password-totp",
        session_id="01SES",
    )
    assert s.expired


# ------------------------------------------------------- login_password

class _StubResponse:
    def __init__(self, body: bytes, status: int = 200):
        self._body = body
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return self._body


def _good_body():
    return json.dumps({
        "token":        "ttiowbs_" + "x" * 43,
        "user_id":      "01HXYUSR",
        "username":     "alice",
        "capabilities": ["containers.read.any_project", "sessions.start"],
        "projects":     ["alpha"],
        "session_id":   "01HXYSES",
        "expires_at":   2_000_000_000,
        "provider":     "password-totp",
    }).encode("utf-8")


def test_login_password_happy_path(monkeypatch):
    captured = {}

    def fake_urlopen(req, timeout):
        captured["url"] = req.full_url
        captured["data"] = json.loads(req.data)
        captured["method"] = req.get_method()
        captured["headers"] = dict(req.header_items())
        return _StubResponse(_good_body())

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    session = login_password("localhost", 8443, "alice", "pw", "012345")

    # The request shape matches the smoke harness verbatim.
    assert captured["url"] == "http://localhost:8443/v1/auth/login"
    assert captured["method"] == "POST"
    assert captured["data"] == {
        "username": "alice", "password": "pw", "totp": "012345"}
    assert captured["headers"]["Content-type"] == "application/json"

    # The Session is wired through correctly.
    assert session.token.startswith("ttiowbs_")
    assert session.username == "alice"
    assert session.has_capability("sessions.start")
    assert session.projects == ("alpha",)


def test_login_password_https_scheme(monkeypatch):
    captured = {}

    def fake_urlopen(req, timeout):
        captured["url"] = req.full_url
        return _StubResponse(_good_body())

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    login_password("workbench.example.com", 8443, "a", "b", "012345",
                    scheme="https")
    assert captured["url"].startswith("https://")


def _http_error(code: int, body: dict, headers: dict | None = None):
    return urllib.error.HTTPError(
        url="http://x/", code=code, msg="x",
        hdrs=headers or {},
        fp=io.BytesIO(json.dumps(body).encode("utf-8")))


def test_login_password_401_raises_invalid_credentials(monkeypatch):
    def fake_urlopen(req, timeout):
        raise _http_error(401, {"error": "invalid credentials"})
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(InvalidCredentials, match="invalid credentials"):
        login_password("localhost", 8443, "a", "b", "012345")


def test_login_password_423_raises_account_disabled(monkeypatch):
    def fake_urlopen(req, timeout):
        raise _http_error(423, {"error": "account disabled"})
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(AccountDisabled, match="account disabled"):
        login_password("localhost", 8443, "a", "b", "012345")


def test_login_password_429_raises_rate_limit(monkeypatch):
    class _FakeHeaders(dict):
        # urllib.error.HTTPError expects .headers to behave like
        # an HTTPMessage; .get("Retry-After") works on a plain dict.
        pass

    def fake_urlopen(req, timeout):
        raise _http_error(429, {"error": "rate limit exceeded"},
                            headers=_FakeHeaders({"Retry-After": "30"}))
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(RateLimitExceeded) as ei:
        login_password("localhost", 8443, "a", "b", "012345")
    assert ei.value.retry_after_seconds == 30


def test_login_password_bad_token_shape_rejects(monkeypatch):
    body = json.loads(_good_body())
    body["token"] = "wrong_prefix_abc"
    def fake_urlopen(req, timeout):
        return _StubResponse(json.dumps(body).encode("utf-8"))
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(WorkbenchAuthError, match="token.*unexpected shape"):
        login_password("localhost", 8443, "a", "b", "012345")


def test_login_password_missing_required_field(monkeypatch):
    body = json.loads(_good_body())
    body.pop("session_id")
    def fake_urlopen(req, timeout):
        return _StubResponse(json.dumps(body).encode("utf-8"))
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(WorkbenchAuthError, match="missing required field"):
        login_password("localhost", 8443, "a", "b", "012345")
