"""
ttio.workbench.auth -- workbench-server login flow + TOTP + session.

Targets `tti-workbench-server` v1.0.0's `/v1/auth/login` endpoint
(see `tti-workbench-server/Documentation/auth.md`). Login requires
username + password + RFC 6238 TOTP; on success the server returns
a bearer token (`ttiowbs_<43-char base64url>`), the user's
capability flags, projects, and an `expires_at` unix epoch.

Capability flags are dot-delimited strings
(`containers.write.own_project`, `sessions.start`, etc.). They're
opaque to the client but cached on the `Session` so SDK callers can
check ahead before issuing a request.

TOTP semantics: RFC 6238 with HMAC-SHA1, 30-second time-step,
6 digits, T0=0. The server tolerates +/- 1 step skew.

Token storage: in-memory only -- the W1 contract is that bearer
tokens are never written to disk. The CLI's `--staging-root` path
(bootstrap-admin auto-login) reads the password + TOTP secret from
a 0600 file the daemon staged, but the resulting bearer stays
in-memory for the CLI invocation's lifetime.
"""

from __future__ import annotations

import base64
import dataclasses
import hashlib
import hmac
import json
import struct
import time
import urllib.error
import urllib.request
from typing import Optional


class WorkbenchAuthError(Exception):
    """Base class for `/v1/auth/login` failures."""


class InvalidCredentials(WorkbenchAuthError):
    """HTTP 401 -- username/password/TOTP mismatch (collapsed by the
    server to defeat brute-force enumeration). Indistinguishable on
    the wire from unknown-username, so the client surface mirrors
    that opacity."""


class AccountDisabled(WorkbenchAuthError):
    """HTTP 423 -- the user row is marked `disabled_at`."""


class RateLimitExceeded(WorkbenchAuthError):
    """HTTP 429 -- the daemon's auth bucket is empty. The exception
    carries the `retry_after_seconds` hint from the `Retry-After`
    header when present."""

    def __init__(self, message: str, retry_after_seconds: Optional[int] = None):
        super().__init__(message)
        self.retry_after_seconds = retry_after_seconds


@dataclasses.dataclass(frozen=True)
class Session:
    """Authenticated workbench session.

    Returned from `login_password` (and, in W2, from OIDC + API-key
    paths). Holds the bearer token plus enough metadata for callers
    to gate operations without re-hitting the server. Immutable;
    re-login on expiry rather than mutating in place.
    """

    token: str
    """Bearer token for `Authorization: Bearer <token>` (REST) and
    the `token` field in WebSocket handshake JSON. Always prefixed
    with `ttiowbs_` for v1.0 servers."""

    username: str

    user_id: str
    """The server's ULID for the user row. Stable across logins."""

    capabilities: frozenset[str]
    """Capability flags (`containers.write.own_project`, etc.).
    Opaque to the client; the SDK checks containment ahead of REST
    calls that need them."""

    projects: tuple[str, ...]
    """Projects the user is a member of. Required when the user
    lacks the `containers.*.any_project` flag."""

    expires_at: int
    """Unix epoch seconds at which the server will reject this
    token. Default v1.0 lifetime is 24 hours."""

    provider: str
    """Auth provider that issued this session. v1.0:
    `password-totp`. W2+ may add `oidc`, `api-key`."""

    session_id: str
    """ULID of the row in the daemon's `sessions` table. Used by the
    logout endpoint (W2) to revoke this specific session without
    touching the user's other sessions."""

    @property
    def expired(self) -> bool:
        return time.time() >= self.expires_at

    def authorization_header(self) -> str:
        return f"Bearer {self.token}"

    def has_capability(self, name: str) -> bool:
        return name in self.capabilities


def current_totp(secret_b32: str, *, t: Optional[float] = None) -> str:
    """Compute the current RFC 6238 TOTP for `secret_b32`.

    Args:
        secret_b32: base32-encoded TOTP secret (the format the daemon
            writes into `bootstrap-credentials.json` and the format
            authenticator apps consume).
        t: optional unix epoch override (defaults to `time.time()`).
            Used by tests to pin a deterministic counter.

    Returns:
        Six-digit decimal string, zero-padded.
    """
    secret = base64.b32decode(secret_b32)
    now = time.time() if t is None else t
    counter = int(now // 30)
    mac = hmac.new(secret, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = mac[-1] & 0x0F
    bin_code = (
        ((mac[off] & 0x7F) << 24)
        | (mac[off + 1] << 16)
        | (mac[off + 2] << 8)
        | mac[off + 3]
    )
    return f"{bin_code % 1_000_000:06d}"


def login_password(
    host: str,
    port: int,
    username: str,
    password: str,
    totp: str,
    *,
    scheme: str = "http",
    timeout: float = 5.0,
) -> Session:
    """POST `/v1/auth/login` and return a `Session`.

    Args:
        host: server hostname or IP.
        port: server REST port.
        username, password, totp: credentials to post.
        scheme: `"http"` or `"https"`. Default `"http"` for the
            development / loopback path; production deployments
            should always pass `"https"`.
        timeout: request timeout in seconds.

    Raises:
        InvalidCredentials: server returned 401.
        AccountDisabled: server returned 423.
        RateLimitExceeded: server returned 429.
        WorkbenchAuthError: any other failure (network, malformed
            response, unexpected status). The underlying exception is
            chained via `__cause__`.
    """
    payload = json.dumps({
        "username": username,
        "password": password,
        "totp":     totp,
    }).encode("utf-8")
    url = f"{scheme}://{host}:{port}/v1/auth/login"
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            body = json.loads(raw)
    except urllib.error.HTTPError as e:
        _raise_http_error(e)
    except (urllib.error.URLError, OSError) as e:
        raise WorkbenchAuthError(f"login transport error: {e}") from e
    except json.JSONDecodeError as e:
        raise WorkbenchAuthError(f"login response not JSON: {e}") from e

    return _session_from_response(body, provider="password-totp")


def _raise_http_error(e: urllib.error.HTTPError) -> None:
    """Translate the daemon's `{"error": "..."}` envelope (see
    `Source/HTTP/handlers/TTIOWBAuthHandler.m`) into typed exceptions."""
    body_text = ""
    try:
        body_text = e.read().decode("utf-8", errors="replace")
    except Exception:
        pass
    message = body_text
    try:
        parsed = json.loads(body_text)
        if isinstance(parsed, dict) and isinstance(parsed.get("error"), str):
            message = parsed["error"]
    except json.JSONDecodeError:
        pass

    if e.code == 401:
        raise InvalidCredentials(message or "invalid credentials") from e
    if e.code == 423:
        raise AccountDisabled(message or "account disabled") from e
    if e.code == 429:
        retry_after = e.headers.get("Retry-After") if e.headers else None
        try:
            retry_after_int = int(retry_after) if retry_after else None
        except ValueError:
            retry_after_int = None
        raise RateLimitExceeded(
            message or "rate limit exceeded",
            retry_after_seconds=retry_after_int,
        ) from e
    raise WorkbenchAuthError(
        f"login failed: HTTP {e.code}: {message or e.reason}",
    ) from e


def _session_from_response(body: dict, *, provider: str) -> Session:
    """Validate the 200 body shape from `Source/HTTP/handlers/TTIOWBAuthHandler.m`.

    Required keys: token, user_id, username, capabilities, projects,
    session_id, expires_at, provider (when present).
    """
    required = ("token", "user_id", "username", "capabilities",
                 "projects", "session_id", "expires_at")
    for key in required:
        if key not in body:
            raise WorkbenchAuthError(
                f"login response missing required field {key!r}")

    if not isinstance(body["token"], str) or not body["token"].startswith("ttiowbs_"):
        raise WorkbenchAuthError("login response 'token' has unexpected shape")

    caps = body["capabilities"]
    if not isinstance(caps, list) or not all(isinstance(c, str) for c in caps):
        raise WorkbenchAuthError("login response 'capabilities' must be a string list")

    projects = body["projects"]
    if not isinstance(projects, list) or not all(isinstance(p, str) for p in projects):
        raise WorkbenchAuthError("login response 'projects' must be a string list")

    if not isinstance(body["expires_at"], (int, float)):
        raise WorkbenchAuthError("login response 'expires_at' must be numeric")

    return Session(
        token=body["token"],
        username=body["username"],
        user_id=body["user_id"],
        capabilities=frozenset(caps),
        projects=tuple(projects),
        expires_at=int(body["expires_at"]),
        provider=str(body.get("provider", provider)),
        session_id=body["session_id"],
    )
