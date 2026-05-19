"""
ttio.workbench.client -- top-level SDK factory + WorkbenchClient.

The spec section 8.3 sample:

    import ttio
    client = ttio.connect("wss://biobank.thalion.org/transport",
                            auth=ttio.OIDCAuth())
    cohort = client.query(diagnosis="Alzheimer's disease", ...)
    stream = client.stream(container=cohort[0].uri,
                            filters={"chromosome":"chr6", ...})
    subset = stream.materialize()
    job = client.submit_pipeline(pipeline="eqtl-analysis", ...)
    results = job.output_container()

W2 (this module) ships:

  - `connect(url, auth=...)` factory returning `WorkbenchClient`.
  - `WorkbenchClient.upload(...)` / `.download(...)` / `.stream(...)`
    backed by the W1 transport client.
  - `.query()`, `.submit_pipeline()`, `.session_create()` placeholders
    that raise `NotImplementedError` with a clear "W3" / "W4" pointer.
  - `Stream.materialize()` helper that materialises a streamed
    download to a local `.tio` file.

URL parsing: `connect` accepts `wss://host:port/transport`,
`ws://host:port/transport`, `https://host:port`, or
`http://host:port`. The control plane (REST) uses the http/https
sibling of whatever WS scheme is given; the data plane (WS) uses
the WS scheme. Operators typically deploy with shared host:port
and TLS-or-no-TLS for both planes -- the SDK assumes this.
"""

from __future__ import annotations

import dataclasses
import urllib.parse
from typing import Any, Iterable, Mapping, Optional

from ttio.workbench.auth import Session
from ttio.workbench.auth_providers import AuthProvider
from ttio.workbench.transport.download import (
    DownloadClient,
    DownloadResult,
    FilterDict,
    OutputMode,
)
from ttio.workbench.transport.handshake import OutputModeLiteral
from ttio.workbench.transport.resume import ResumeState
from ttio.workbench.transport.upload import UploadClient, UploadResult


@dataclasses.dataclass(frozen=True)
class _Endpoint:
    """Resolved server endpoint. Internal; constructed by `connect()`."""
    host: str
    port: int
    ws_scheme: str          # "ws" or "wss"
    http_scheme: str        # "http" or "https"


def _parse_url(url: str) -> _Endpoint:
    """Parse the user-facing connect URL into host + port + schemes.

    Accepts (in order of typical use):
      - `wss://host:port/transport`  -- the spec sample shape
      - `ws://host:port/transport`   -- dev / loopback
      - `https://host:port`          -- REST-only conveniences
      - `http://host:port`           -- dev / loopback
      - `host:port`                  -- bare; defaults to ws/http
    """
    if "://" not in url:
        url = "ws://" + url
    p = urllib.parse.urlparse(url)
    scheme = p.scheme.lower()
    if scheme in ("ws", "wss"):
        ws_scheme = scheme
        http_scheme = "https" if scheme == "wss" else "http"
    elif scheme in ("http", "https"):
        http_scheme = scheme
        ws_scheme = "wss" if scheme == "https" else "ws"
    else:
        raise ValueError(
            f"unsupported scheme {scheme!r}; expected one of "
            f"ws / wss / http / https")
    if not p.hostname:
        raise ValueError(f"URL missing host: {url!r}")
    port = p.port
    if port is None:
        # Same defaults as the workbench-server deploys: 8443.
        port = 8443
    return _Endpoint(
        host=p.hostname,
        port=port,
        ws_scheme=ws_scheme,
        http_scheme=http_scheme,
    )


class WorkbenchClient:
    """High-level SDK entry point. Holds the authenticated session
    plus the endpoint resolution; spawns short-lived
    `UploadClient` / `DownloadClient` instances per operation.

    Construction is via `ttio.connect(...)` rather than direct
    instantiation; the constructor is `__init__`-public for
    completeness but the factory does the auth round-trip.
    """

    def __init__(self, endpoint: _Endpoint, session: Session,
                  auth: AuthProvider):
        self._endpoint = endpoint
        self._session = session
        self._auth = auth

    @property
    def session(self) -> Session:
        """The current authenticated Session. Re-login via
        `reauth()` rather than mutating this property."""
        return self._session

    @property
    def host(self) -> str: return self._endpoint.host

    @property
    def port(self) -> int: return self._endpoint.port

    @property
    def ws_scheme(self) -> str: return self._endpoint.ws_scheme

    @property
    def http_scheme(self) -> str: return self._endpoint.http_scheme

    def reauth(self) -> None:
        """Re-authenticate using the stored auth provider. Use when
        `session.expired` flips True mid-script."""
        self._session = self._auth.authenticate(
            self._endpoint.host, self._endpoint.port,
            self._endpoint.http_scheme)

    # ----------------------------------------------- data plane

    def upload_client(
        self,
        *,
        project: str,
        container_uri: str,
        chunk_size: Optional[int] = None,
    ) -> UploadClient:
        """Construct a (not-yet-opened) `UploadClient` bound to this
        session + endpoint. Caller drives `async with`."""
        kwargs: dict[str, Any] = dict(
            host=self._endpoint.host,
            port=self._endpoint.port,
            session=self._session,
            project=project,
            container_uri=container_uri,
            scheme=self._endpoint.ws_scheme,
        )
        if chunk_size is not None:
            kwargs["chunk_size"] = chunk_size
        return UploadClient(**kwargs)

    def download_client(self) -> DownloadClient:
        """Construct a (not-yet-opened) `DownloadClient`."""
        return DownloadClient(
            host=self._endpoint.host,
            port=self._endpoint.port,
            session=self._session,
            scheme=self._endpoint.ws_scheme,
        )

    async def upload_bytes(
        self,
        *,
        project: str,
        container_uri: str,
        data: bytes,
        resume: Optional[ResumeState] = None,
    ) -> UploadResult:
        """Convenience: one-shot upload of a buffered byte string."""
        async with self.upload_client(
                project=project, container_uri=container_uri) as up:
            return await up.upload_bytes(data, resume=resume)

    async def download_bytes(
        self,
        *,
        container_uri: str,
        filters: Optional[FilterDict] = None,
        output_mode: OutputMode = OutputModeLiteral.BINARY.value,
        max_au: int = 0,
    ) -> DownloadResult:
        """Convenience: one-shot download to a buffered byte string."""
        async with self.download_client() as dn:
            return await dn.download(
                container_uri=container_uri,
                filter=filters,
                output_mode=output_mode,
                max_au=max_au,
            )

    # ----------------------------------------------- control plane (W3+)

    def query(self, *args, **kwargs):
        """Run a cohort query. **W3 surface** -- raises today."""
        from ttio.workbench.cohort import _not_yet_implemented
        _not_yet_implemented("client.query()", "W3")

    def save_cohort(self, *args, **kwargs):
        """Persist a cohort. **W3 surface** -- raises today."""
        from ttio.workbench.cohort import _not_yet_implemented
        _not_yet_implemented("client.save_cohort()", "W3")

    def submit_pipeline(self, *args, **kwargs):
        """Submit a pipeline run. **W3 surface** -- raises today."""
        from ttio.workbench.pipeline import _not_yet_implemented
        _not_yet_implemented("client.submit_pipeline()", "W3")

    def jobs(self, *args, **kwargs):
        """List / inspect jobs. **W3 surface** -- raises today."""
        from ttio.workbench.jobs import _not_yet_implemented
        _not_yet_implemented("client.jobs()", "W3")

    def session_create(self, *args, **kwargs):
        """Create an interactive session. **W4 surface** -- raises today."""
        from ttio.workbench.sessions import _not_yet_implemented
        _not_yet_implemented("client.session_create()", "W4")


def connect(url: str, *, auth: AuthProvider) -> WorkbenchClient:
    """SDK entry point. Resolve the endpoint, authenticate via the
    given provider, return a `WorkbenchClient`.

    Args:
        url: `wss://host:port/transport`, `ws://host:port/transport`,
            `https://host:port`, `http://host:port`, or bare
            `host:port` (defaults to `ws://` and port 8443).
        auth: an `AuthProvider` (typically
            `PasswordTotpAuth(...)` for v1.0, or `BearerAuth(...)`
            when the caller already holds a token).

    Returns:
        `WorkbenchClient` with the auth round-trip completed.

    Raises:
        `WorkbenchAuthError` and subclasses on auth failure.
        `ValueError` on URL parse failure.
    """
    if auth is None:
        raise ValueError("connect() requires `auth=<AuthProvider>`")
    endpoint = _parse_url(url)
    session = auth.authenticate(endpoint.host, endpoint.port, endpoint.http_scheme)
    return WorkbenchClient(endpoint, session, auth)


# Helper used by spec section 8.3's `cohort[0].uri` style. v1.0
# the W2 SDK doesn't have a Cohort or Container value object yet;
# placeholder lives in the cohort module (W3 will flesh out).
def parse_filter_kv(values: Iterable[str]) -> dict[str, Any]:
    """Parse repeated `--filter k=v` CLI arguments into a dict.

    Used by `ttio download --filter chromosome=chr6 --filter
    position_min=28000000`. Values are auto-coerced to int / float
    when they look numeric; otherwise kept as strings. The server-
    side handshake validator (`build_download_handshake`) catches
    unknown keys with a clear ValueError before opening the WS.
    """
    out: dict[str, Any] = {}
    for raw in values:
        if "=" not in raw:
            raise ValueError(
                f"--filter expects k=v form; got {raw!r}")
        key, value = raw.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            raise ValueError(f"--filter missing key: {raw!r}")
        # Coerce numerics so the filter dict matches the daemon's
        # expected types (e.g. ms_level is an int, retention_time_min
        # is a float).
        coerced: Any
        try:
            coerced = int(value)
        except ValueError:
            try:
                coerced = float(value)
            except ValueError:
                coerced = value
        out[key] = coerced
    return out
