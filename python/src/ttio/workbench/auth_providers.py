"""
ttio.workbench.auth_providers -- pluggable auth providers for the SDK.

Spec section 8.3's sample:

    client = ttio.connect("wss://biobank.thalion.org/transport",
                            auth=ttio.OIDCAuth())

The `auth=` keyword takes any object that can produce an
authenticated `Session`. v1.0 ships:

  - `PasswordTotpAuth(username, password, totp)` -- interactive
    credentials; logs in via `/v1/auth/login`.
  - `BearerAuth(token, owner)` -- caller already holds a bearer
    (e.g. injected by `ttio` CLI's `--token` arg, or by an
    automated pipeline that called `login_password` directly).
  - `BootstrapAdminAuth(staging_root)` -- reads
    `<staging_root>/bootstrap-credentials.json` (mode 0600) and
    logs in as the bootstrap admin. Smoke harness path; not
    intended for production use.
  - `OIDCAuth()` -- stub for v1.1. Raises `NotImplementedError`
    on `.authenticate()` so callers get a clear "OIDC is v1.1"
    error rather than a misleading login failure.

Each provider exposes `.authenticate(host, port, scheme) -> Session`
plus the `.username` it should attribute uploads to. The SDK
caches the Session on the client; re-login is the caller's
choice (no automatic refresh in v1.0 -- bearer tokens are
24-hour lived, which is enough for any reasonable batch job).
"""

from __future__ import annotations

import abc
import dataclasses
import json
import os
from typing import Optional

from ttio.workbench.auth import Session, current_totp, login_password


class AuthProvider(abc.ABC):
    """Abstract auth provider. SDK callers don't typically construct
    one of these directly -- `ttio.connect(..., auth=...)` takes a
    concrete provider, and the provider's `.authenticate()` is
    called once on connect."""

    @abc.abstractmethod
    def authenticate(self, host: str, port: int, scheme: str) -> Session:
        """Resolve to an authenticated `Session`. Called once by
        `connect()`. Raises a typed `WorkbenchAuthError` subclass on
        failure."""

    @property
    @abc.abstractmethod
    def username(self) -> str:
        """Username the SDK will use as the WS handshake `owner`
        field for uploads. Surfaced as a property so the SDK can
        validate ahead of opening the WS."""


@dataclasses.dataclass(frozen=True)
class PasswordTotpAuth(AuthProvider):
    """Interactive credentials. The TOTP is fetched once at
    construction time; if it has expired by the time `authenticate`
    is called, login will fail with `InvalidCredentials` and the
    caller must construct a new provider."""

    username_: str
    password: str
    totp: str

    @property
    def username(self) -> str:
        return self.username_

    def authenticate(self, host: str, port: int, scheme: str) -> Session:
        return login_password(host, port, self.username_,
                                self.password, self.totp, scheme=scheme)


@dataclasses.dataclass(frozen=True)
class BearerAuth(AuthProvider):
    """Caller already holds a bearer token. No round-trip on
    `authenticate` -- we synthesise a minimal `Session` from the
    inputs. The token's actual expiry / capability set isn't
    visible to the client; pre-flight failures surface when the
    first REST or WS call hits the daemon."""

    token: str
    username_: str
    projects: tuple[str, ...] = ()
    capabilities: frozenset[str] = frozenset()
    expires_at: int = 0  # 0 = unknown; client treats as never-expires

    @property
    def username(self) -> str:
        return self.username_

    def authenticate(self, host: str, port: int, scheme: str) -> Session:
        return Session(
            token=self.token,
            username=self.username_,
            user_id="",          # unknown without round-trip
            capabilities=self.capabilities,
            projects=self.projects,
            expires_at=self.expires_at,
            provider="bearer",
            session_id="",       # unknown without round-trip
        )


@dataclasses.dataclass(frozen=True)
class BootstrapAdminAuth(AuthProvider):
    """Reads `<staging_root>/bootstrap-credentials.json` (mode 0600,
    written by `tti-workbench-server` on first boot) and logs in as
    the bootstrap admin. Mirrors the smoke harness path in
    `tti-workbench-server/Tests/load/upload_one.py`.

    NOT intended for production use -- operators are expected to
    rotate the bootstrap admin out after first login. Useful for
    local development, smoke tests, and the CLI's
    `--staging-root` flag.
    """

    staging_root: str

    @property
    def username(self) -> str:
        path = os.path.join(self.staging_root, "bootstrap-credentials.json")
        with open(path) as f:
            return json.load(f)["username"]

    def authenticate(self, host: str, port: int, scheme: str) -> Session:
        path = os.path.join(self.staging_root, "bootstrap-credentials.json")
        with open(path) as f:
            creds = json.load(f)
        return login_password(
            host, port,
            creds["username"], creds["password"],
            current_totp(creds["totp_secret_base32"]),
            scheme=scheme)


class OIDCAuth(AuthProvider):
    """v1.1 stub. The spec section 10.1 marks OIDC as the primary
    production auth mechanism; v1.0 servers only speak password +
    TOTP. This class exists so spec section 8.3's sample
    (`auth=ttio.OIDCAuth()`) is import-clean today; calling
    `.authenticate()` raises a clear "v1.1" error rather than a
    misleading login failure.
    """

    def __init__(self, issuer: Optional[str] = None,
                  client_id: Optional[str] = None):
        self._issuer = issuer
        self._client_id = client_id

    @property
    def username(self) -> str:
        raise NotImplementedError(
            "OIDC auth is a v1.1 feature; the v1.0 workbench server "
            "speaks password + TOTP only. Use "
            "`ttio.PasswordTotpAuth(username, password, totp)` instead."
        )

    def authenticate(self, host: str, port: int, scheme: str) -> Session:
        raise NotImplementedError(
            "OIDC auth is a v1.1 feature; the v1.0 workbench server "
            "speaks password + TOTP only. Use "
            "`ttio.PasswordTotpAuth(username, password, totp)` instead."
        )
