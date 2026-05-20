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
from ttio.workbench.encryption import (
    ProtectionMetadata,
    ProtectionMode,
    open_sealed,
    seal,
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

    async def upload_protected(
        self,
        *,
        project: str,
        container_uri: str,
        data: bytes,
        mode: ProtectionMode,
        dek: Optional[bytes] = None,
        kek: Optional[bytes] = None,
        kek_algorithm: str = "aes-256-gcm",
        resume: Optional[ResumeState] = None,
    ) -> tuple[UploadResult, ProtectionMetadata]:
        """Seal `data` (BYOK or envelope) and upload the ciphertext.

        Returns the `UploadResult` plus the `ProtectionMetadata` the
        caller must retain to decrypt later (for ENVELOPE this carries
        the wrapped DEK; for BYOK it carries no key material -- the
        researcher holds the DEK out of band).
        """
        sealed = seal(data, mode=mode, dek=dek, kek=kek,
                      kek_algorithm=kek_algorithm)
        result = await self.upload_bytes(
            project=project, container_uri=container_uri,
            data=sealed.ciphertext, resume=resume)
        return result, sealed.protection

    async def download_and_open(
        self,
        *,
        container_uri: str,
        protection: ProtectionMetadata,
        dek: Optional[bytes] = None,
        kek: Optional[bytes] = None,
        filters: Optional[FilterDict] = None,
        max_au: int = 0,
    ) -> bytes:
        """Download a sealed payload and decrypt it. BYOK: pass `dek`.
        ENVELOPE: pass the `kek` that unwraps `protection.wrapped_dek`."""
        result = await self.download_bytes(
            container_uri=container_uri, filters=filters, max_au=max_au)
        return open_sealed(result.payload, protection, dek=dek, kek=kek)

    # ----------------------------------------------- control plane (W3)

    def query(self, query) -> "CohortResult":  # noqa: F821 -- forward ref
        """Run a cohort query. POSTs `/v1/cohorts/query`; returns
        a `CohortResult`.

        Args:
            query: a `CohortQuery` instance, or a dict in the
                server's JSON shape.
        """
        from ttio.workbench.cohort import CohortQuery, CohortResult
        from ttio.workbench._http import WorkbenchHttpError, http_json

        body = query.to_json() if isinstance(query, CohortQuery) else dict(query)
        status, resp = http_json(
            "POST", self._endpoint.host, self._endpoint.port,
            "/v1/cohorts/query",
            scheme=self._endpoint.http_scheme,
            token=self._session.token, body=body)
        if status != 200:
            raise WorkbenchHttpError(
                f"POST /v1/cohorts/query failed: {status}",
                status=status, body=resp)
        return CohortResult.from_json(resp)

    def preview_count(self, query) -> int:
        """POST `/v1/cohorts/preview-count`; return the predicted row
        count. Lets the GUI / CLI show "this will return N rows" before
        a full query."""
        from ttio.workbench.cohort import CohortQuery
        from ttio.workbench._http import WorkbenchHttpError, http_json

        body = query.to_json() if isinstance(query, CohortQuery) else dict(query)
        status, resp = http_json(
            "POST", self._endpoint.host, self._endpoint.port,
            "/v1/cohorts/preview-count",
            scheme=self._endpoint.http_scheme,
            token=self._session.token, body=body)
        if status != 200:
            raise WorkbenchHttpError(
                f"POST /v1/cohorts/preview-count failed: {status}",
                status=status, body=resp)
        return int(resp.get("count", 0))

    def containers(self):
        """Return a `ContainersClient` bound to this session."""
        from ttio.workbench.containers import ContainersClient
        return ContainersClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def pipelines(self):
        """Return a `PipelinesClient` bound to this session."""
        from ttio.workbench.pipeline import PipelinesClient
        return PipelinesClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def submit_pipeline(self, *, pipeline_id: str,
                          inputs, params=None):
        """Convenience: submit a job. Returns a `Job` handle.

        For more control (status filter on list, SSE long-poll),
        use `client.jobs()` directly.
        """
        return self.jobs().submit(
            pipeline_id=pipeline_id, inputs=inputs, params=params)

    def jobs(self):
        """Return a `JobsClient` bound to this session."""
        from ttio.workbench.jobs import JobsClient
        return JobsClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def sessions(self):
        """Return a `SessionsClient` bound to this session."""
        from ttio.workbench.sessions import SessionsClient
        return SessionsClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def session_create(self, *, project: str, engine_pin: str,
                         image=None, command=None, env=None,
                         bind_mounts=None,
                         container_storage_root=None):
        """Convenience: POST /v1/sessions. Returns a `Session`
        handle in `starting` state."""
        return self.sessions().create(
            project=project, engine_pin=engine_pin,
            image=image, command=command, env=env,
            bind_mounts=bind_mounts,
            container_storage_root=container_storage_root,
        )

    def session_proxy(self, session_id: str, *, path: str = "/"):
        """Return an unopened `SessionProxyAttach` bound to this
        session + endpoint. Caller drives the async context manager.
        """
        from ttio.workbench.session_proxy import SessionProxyAttach
        return SessionProxyAttach(
            host=self._endpoint.host, port=self._endpoint.port,
            session_id=session_id, token=self._session.token,
            path=path, scheme=self._endpoint.ws_scheme)


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
