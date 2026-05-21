"""
ttio.workbench -- TTI-O Workbench Client SDK.

Client surface against `tti-workbench-server` v1.0.0+ (the multi-worker
ObjC/GNUstep/libwebsockets daemon). Distinct from `ttio.transport`,
which targets the Python reference server (no auth, no
`container_uri`, no project/owner).

W1 (this module) ships:

  - `ttio.workbench.auth` -- login flow, RFC 6238 TOTP, Session token
    holder.
  - `ttio.workbench.transport` -- workbench-aware upload + download +
    filtered streaming + resumable uploads over the `ttio-transport`
    WebSocket subprotocol.

Future Ws add:

  - W2: `ttio.workbench.client` top-level `connect()` factory and the
    spec section 8.3 SDK shape (`client.query`, `.stream`,
    `.materialize`).
  - W3: `ttio.workbench.cohort`, `.pipeline`, `.jobs`, `.provenance`.
  - W4: `ttio.workbench.sessions`, `.session_proxy`.
  - W6: per-AU encrypted upload on `WorkbenchClient`
    (`upload_encrypted` / `_envelope` / `_pqc`); `ttio.workbench.pqc`
    supplies the ML-KEM keypair generator + preview gate.

The workbench wire contract is documented in
`tti-workbench-server/Documentation/{auth, upload-protocol,
download-protocol}.md`. The W1 survey + gap analysis lives in
`docs/workbench-client-workplan.md` in this repo.
"""

from ttio.workbench.auth import (
    AccountDisabled,
    InvalidCredentials,
    RateLimitExceeded,
    Session,
    WorkbenchAuthError,
    current_totp,
    login_password,
)
from ttio.workbench.auth_providers import (
    AuthProvider,
    BearerAuth,
    BootstrapAdminAuth,
    OIDCAuth,
    PasswordTotpAuth,
)
from ttio.workbench.client import (
    WorkbenchClient,
    connect,
    parse_filter_kv,
)

__all__ = [
    # auth
    "AccountDisabled",
    "InvalidCredentials",
    "RateLimitExceeded",
    "Session",
    "WorkbenchAuthError",
    "current_totp",
    "login_password",
    # auth providers
    "AuthProvider",
    "BearerAuth",
    "BootstrapAdminAuth",
    "OIDCAuth",
    "PasswordTotpAuth",
    # client / SDK
    "WorkbenchClient",
    "connect",
    "parse_filter_kv",
]
