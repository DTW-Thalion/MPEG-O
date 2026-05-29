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
import json
import os
import urllib.parse
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Optional, Union

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
class EnvelopeRecipient:
    """One recipient of a multi-recipient encrypted upload (FD-1 Phase B).

    The same per-run DEK is wrapped once per recipient under ``key``:

    * ``algorithm="aes-256-gcm"`` -- ``key`` is a 32-byte symmetric KEK.
    * ``algorithm="ml-kem-1024"`` -- ``key`` is a 1568-byte ML-KEM-1024
      public key.

    ``recipient_id`` is an opaque label the downloader uses to select its
    entry; ids must be unique within an upload. The first recipient passed
    to :meth:`WorkbenchClient.upload_encrypted_multi` becomes the packet's
    *primary* (its id is normalised to ``""`` on the wire, per the Phase A
    spec); recover it on download with ``recipient_id=""``.
    """
    recipient_id: str
    key: bytes
    algorithm: str = "aes-256-gcm"


@dataclasses.dataclass(frozen=True)
class ServerRecipient:
    """A recipient that delegates the DEK wrap to the daemon's
    server-side key custody (FD-1-PF-4).

    Instead of the caller supplying the KEK bytes (which they won't
    have, since the KEK is HSM-resident), the daemon wraps the DEK on
    the client's behalf via the ``/v1/key-custody/wrap-for-server``
    REST endpoint. The resulting wrapped blob is indistinguishable at
    the packet level from an :class:`EnvelopeRecipient` with
    ``algorithm="aes-256-gcm"``.

    ``recipient_id`` follows the same convention as
    :class:`EnvelopeRecipient`: ``""`` for the primary (first)
    recipient; non-empty unique strings for additional ones.

    ``kek_id`` is an opaque string naming the PKCS#11 key on the
    daemon; the daemon resolves it to the actual key material. The
    same ``kek_id`` is stamped into the ``server_kek_id`` field of
    ``ProtectionMetadata`` so the daemon can identify which key to
    use on the re-processing path.
    """
    recipient_id: str
    kek_id: str
    algorithm: str = "aes-256-gcm"


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
        """Construct a workbench client from a resolved endpoint + session.

        Instances are normally produced by :func:`connect`, which does
        the URL parse, runs the auth round-trip via ``auth``, then
        passes both into this constructor. Direct construction is
        valid when the caller already holds a :class:`Session` (e.g.
        when adopting a token-paste session).

        Parameters
        ----------
        endpoint : _Endpoint
            Resolved host / port / WS scheme / HTTP scheme tuple.
        session : Session
            Authenticated session backing every outbound request.
        auth : AuthProvider
            Provider stored for use by :meth:`reauth`.
        """
        self._endpoint = endpoint
        self._session = session
        self._auth = auth

    @property
    def session(self) -> Session:
        """The current authenticated :class:`Session`.

        Read-only from the caller's perspective. Use :meth:`reauth`
        rather than mutating this property when the session expires.
        """
        return self._session

    @property
    def host(self) -> str:
        """Server hostname resolved from the connect URL."""
        return self._endpoint.host

    @property
    def port(self) -> int:
        """Server TCP port (default ``8443`` when the URL omits one)."""
        return self._endpoint.port

    @property
    def ws_scheme(self) -> str:
        """WebSocket URL scheme — ``"ws"`` or ``"wss"``."""
        return self._endpoint.ws_scheme

    @property
    def http_scheme(self) -> str:
        """REST URL scheme — ``"http"`` or ``"https"``."""
        return self._endpoint.http_scheme

    def reauth(self) -> None:
        """Re-authenticate using the stored auth provider.

        Calls ``auth.authenticate`` against the same endpoint and
        replaces :attr:`session` with the result. Use when
        :attr:`Session.expired` flips ``True`` mid-script (e.g.
        long-running ingest loops outliving the token TTL).

        Raises
        ------
        WorkbenchAuthError
            From the underlying provider, e.g. on bad credentials.
        """
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
        """Construct an unopened :class:`UploadClient` for one transfer.

        Parameters
        ----------
        project : str
            Project the container belongs to.
        container_uri : str
            Client-minted container URI (e.g.
            ``"uri:tio:demo-001"``).
        chunk_size : int, optional
            Per-WS-frame byte budget. ``None`` (default) lets
            :class:`UploadClient` pick its built-in default
            (64 KiB).

        Returns
        -------
        UploadClient
            The client is *not* yet opened; the caller drives
            ``async with`` to perform the handshake and upload.
        """
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
        """Construct an unopened :class:`DownloadClient` for one transfer.

        Returns
        -------
        DownloadClient
            Bound to this session and endpoint. The caller drives
            ``async with`` to perform the handshake and download.
        """
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
        """Upload a fully-buffered ``.tis`` byte string in one call.

        Convenience wrapper that opens an :class:`UploadClient` and
        calls :meth:`UploadClient.upload_bytes`.

        Parameters
        ----------
        project : str
            Project the container belongs to.
        container_uri : str
            Client-minted container URI.
        data : bytes
            Complete transport stream to upload.
        resume : ResumeState, optional
            Continue a previously-interrupted upload of the same
            container; the server skips bytes it has already
            acknowledged.

        Returns
        -------
        UploadResult

        Raises
        ------
        HandshakeError
            On handshake-time failures.
        UploadError
            On mid-stream failures.
        """
        async with self.upload_client(
                project=project, container_uri=container_uri) as up:
            return await up.upload_bytes(data, resume=resume)

    async def upload_path(
        self,
        *,
        project: str,
        container_uri: str,
        path: str | os.PathLike[str],
        resume: Optional[ResumeState] = None,
        progress: Optional[Callable[[int, int], None]] = None,
        chunk_size: Optional[int] = None,
    ) -> UploadResult:
        """Stream a ``.tis`` file from disk to the server in
        chunkSize-bounded slices. Peak memory is O(``chunk_size``);
        the file is **never** fully buffered in RAM.

        Mirrors Java's ``WorkbenchClient.upload(Path)``.
        """
        async with self.upload_client(
                project=project, container_uri=container_uri,
                chunk_size=chunk_size) as up:
            return await up.upload_path(
                path, resume=resume, progress=progress,
            )

    async def download_bytes(
        self,
        *,
        container_uri: str,
        filters: Optional[FilterDict] = None,
        output_mode: OutputMode = OutputModeLiteral.BINARY.value,
        max_au: int = 0,
    ) -> DownloadResult:
        """Download a container into a fully-buffered byte string in one call.

        Convenience wrapper that opens a :class:`DownloadClient` and
        calls :meth:`DownloadClient.download`.

        Parameters
        ----------
        container_uri : str
            URI of the container to fetch.
        filters : FilterDict, optional
            Server-side filter dictionary (e.g. ``{"chromosome":
            "chr6"}``). ``None`` (default) downloads the full
            container.
        output_mode : OutputMode, optional
            Wire output mode. Default is binary (``.tis`` bytes).
        max_au : int, optional
            Cap on the number of access units to return. ``0``
            (default) means no cap.

        Returns
        -------
        DownloadResult
            Bytes plus any post-transfer metadata.
        """
        async with self.download_client() as dn:
            return await dn.download(
                container_uri=container_uri,
                filter=filters,
                output_mode=output_mode,
                max_au=max_au,
            )

    async def upload_encrypted(
        self,
        *,
        project: str,
        container_uri: str,
        tio_path: str,
        key: bytes,
        encrypt_headers: bool = False,
        resume: Optional[ResumeState] = None,
    ) -> UploadResult:
        """Encrypt a plaintext `.tio` per-AU and upload it.

        The channel payloads (and AU headers when `encrypt_headers`) are
        AES-256-GCM-encrypted *inside* a valid `.tis` transport stream
        that also carries a `ProtectionMetadata` packet, so the daemon
        ingests and re-emits it like any stream (it never sees plaintext
        and holds no key). Recover the data with `download_decrypted`
        using the same `key`.

        The source `.tio` is never mutated -- a temp copy is encrypted.
        """
        import io as _io
        import os
        import shutil
        import tempfile

        from ttio.encryption_per_au import encrypt_per_au
        from ttio.transport.codec import TransportWriter
        from ttio.transport.encrypted import write_encrypted_dataset

        with tempfile.TemporaryDirectory() as d:
            enc_tio = os.path.join(d, "enc.tio")
            shutil.copyfile(tio_path, enc_tio)
            encrypt_per_au(enc_tio, key, encrypt_headers=encrypt_headers)
            stream = _io.BytesIO()
            with TransportWriter(stream) as tw:
                write_encrypted_dataset(tw, enc_tio)
            tis = stream.getvalue()

        return await self.upload_bytes(
            project=project, container_uri=container_uri,
            data=tis, resume=resume)

    async def download_decrypted(
        self,
        *,
        container_uri: str,
        key: bytes,
        out_tio_path: str,
        filters: Optional[FilterDict] = None,
        max_au: int = 0,
    ):
        """Download a per-AU-encrypted container and decrypt it.

        Materialises the still-encrypted `.tio` to `out_tio_path`
        (ciphertext preserved, `opt_per_au_encryption` set) and returns
        the decrypted channel values as
        `{run_name: {channel_name: ndarray}}`. The same `key` used by
        `upload_encrypted` is required.
        """
        import io as _io

        from ttio.encryption_per_au import decrypt_per_au
        from ttio.transport.encrypted import read_encrypted_to_file

        dl = await self.download_bytes(
            container_uri=container_uri, filters=filters, max_au=max_au)
        read_encrypted_to_file(_io.BytesIO(dl.payload), out_tio_path)
        return decrypt_per_au(out_tio_path, key)

    # ----------------------------------------- PQC variant (opt_pqc_preview)

    async def upload_encrypted_pqc(
        self,
        *,
        project: str,
        container_uri: str,
        tio_path: str,
        recipient_public_key: bytes,
        preview: bool = False,
        encrypt_headers: bool = False,
        resume: Optional[ResumeState] = None,
    ) -> UploadResult:
        """Per-AU encrypt a `.tio` with a fresh DEK, wrap that DEK under
        the recipient's ML-KEM-1024 public key, and upload.

        Same daemon-faithful path as :meth:`upload_encrypted` (per-AU
        AES-256-GCM inside a valid `.tis`), but the per-run DEK is not
        caller-held: it is randomly generated, ML-KEM-wrapped, and carried
        in the `ProtectionMetadata` packet. Only the holder of the matching
        ML-KEM private key can recover it via
        :meth:`download_decrypted_pqc`. The daemon never holds a key.

        Preview-gated to mirror the server's ``opt_pqc_preview``: raises
        :class:`~ttio.workbench.pqc.PQCPreviewDisabledError` unless
        ``preview=True``.
        """
        import io as _io
        import os
        import shutil
        import tempfile

        from ttio.encryption_per_au import encrypt_per_au
        from ttio.key_rotation import _wrap_dek
        from ttio.transport.codec import TransportWriter
        from ttio.transport.encrypted import (
            stamp_transport_wrapped_dek,
            write_encrypted_dataset,
        )
        from ttio.workbench.pqc import ML_KEM_1024, _require_preview

        _require_preview(preview)
        dek = os.urandom(32)
        with tempfile.TemporaryDirectory() as d:
            enc_tio = os.path.join(d, "enc.tio")
            shutil.copyfile(tio_path, enc_tio)
            encrypt_per_au(enc_tio, dek, encrypt_headers=encrypt_headers)
            wrapped = _wrap_dek(dek, recipient_public_key,
                                algorithm=ML_KEM_1024)
            stamp_transport_wrapped_dek(enc_tio, wrapped, ML_KEM_1024)
            stream = _io.BytesIO()
            with TransportWriter(stream) as tw:
                write_encrypted_dataset(tw, enc_tio)
            tis = stream.getvalue()

        return await self.upload_bytes(
            project=project, container_uri=container_uri,
            data=tis, resume=resume)

    async def download_decrypted_pqc(
        self,
        *,
        container_uri: str,
        recipient_private_key: bytes,
        out_tio_path: str,
        preview: bool = False,
        filters: Optional[FilterDict] = None,
        max_au: int = 0,
    ):
        """Download a PQC per-AU-encrypted container and decrypt it.

        Materialises the still-encrypted `.tio`, unwraps the per-run DEK
        from the `ProtectionMetadata` using the recipient's ML-KEM-1024
        private key, then returns the decrypted channel values as
        `{run_name: {channel_name: ndarray}}`. Counterpart to
        :meth:`upload_encrypted_pqc`; preview-gated the same way.
        """
        import io as _io

        from ttio.encryption_per_au import decrypt_per_au
        from ttio.key_rotation import _unwrap_dek
        from ttio.transport.encrypted import (
            read_encrypted_to_file,
            read_transport_wrapped_dek,
        )
        from ttio.workbench.pqc import ML_KEM_1024, _require_preview

        _require_preview(preview)
        dl = await self.download_bytes(
            container_uri=container_uri, filters=filters, max_au=max_au)
        read_encrypted_to_file(_io.BytesIO(dl.payload), out_tio_path)
        wrapped, kek_algorithm = read_transport_wrapped_dek(out_tio_path)
        if not wrapped:
            raise ValueError(
                "container carries no wrapped DEK; not a PQC/envelope "
                "upload (use download_decrypted with the BYOK key instead)")
        dek = _unwrap_dek(wrapped, recipient_private_key,
                          algorithm=kek_algorithm or ML_KEM_1024)
        return decrypt_per_au(out_tio_path, dek)

    # ------------------------------------------- envelope variant (KEK-wrap)

    async def upload_encrypted_envelope(
        self,
        *,
        project: str,
        container_uri: str,
        tio_path: str,
        kek: bytes,
        encrypt_headers: bool = False,
        resume: Optional[ResumeState] = None,
    ) -> UploadResult:
        """Per-AU encrypt a `.tio` with a fresh DEK, wrap that DEK under a
        symmetric AES-256-GCM key-encryption key (KEK), and upload.

        Same daemon-faithful path as :meth:`upload_encrypted_pqc`, but the
        per-run DEK is wrapped with a 32-byte symmetric KEK
        (``aes-256-gcm``) instead of an ML-KEM public key. The wrapped DEK
        travels in the `ProtectionMetadata` packet; the daemon never holds
        the KEK. Recover the data with :meth:`download_decrypted_envelope`
        using the same `kek`. Not preview-gated (unlike the PQC variant).
        """
        import io as _io
        import os
        import shutil
        import tempfile

        from ttio.encryption_per_au import encrypt_per_au
        from ttio.key_rotation import _wrap_dek
        from ttio.transport.codec import TransportWriter
        from ttio.transport.encrypted import (
            stamp_transport_wrapped_dek,
            write_encrypted_dataset,
        )

        dek = os.urandom(32)
        with tempfile.TemporaryDirectory() as d:
            enc_tio = os.path.join(d, "enc.tio")
            shutil.copyfile(tio_path, enc_tio)
            encrypt_per_au(enc_tio, dek, encrypt_headers=encrypt_headers)
            wrapped = _wrap_dek(dek, kek, algorithm="aes-256-gcm")
            stamp_transport_wrapped_dek(enc_tio, wrapped, "aes-256-gcm")
            stream = _io.BytesIO()
            with TransportWriter(stream) as tw:
                write_encrypted_dataset(tw, enc_tio)
            tis = stream.getvalue()

        return await self.upload_bytes(
            project=project, container_uri=container_uri,
            data=tis, resume=resume)

    async def download_decrypted_envelope(
        self,
        *,
        container_uri: str,
        kek: bytes,
        out_tio_path: str,
        filters: Optional[FilterDict] = None,
        max_au: int = 0,
    ):
        """Download an envelope per-AU-encrypted container and decrypt it.

        Materialises the still-encrypted `.tio`, unwraps the per-run DEK
        from the `ProtectionMetadata` with the symmetric AES-256-GCM `kek`,
        then returns the decrypted channel values as
        `{run_name: {channel_name: ndarray}}`. Counterpart to
        :meth:`upload_encrypted_envelope`.
        """
        import io as _io

        from ttio.encryption_per_au import decrypt_per_au
        from ttio.key_rotation import _unwrap_dek
        from ttio.transport.encrypted import (
            read_encrypted_to_file,
            read_transport_wrapped_dek,
        )

        dl = await self.download_bytes(
            container_uri=container_uri, filters=filters, max_au=max_au)
        read_encrypted_to_file(_io.BytesIO(dl.payload), out_tio_path)
        wrapped, kek_algorithm = read_transport_wrapped_dek(out_tio_path)
        if not wrapped:
            raise ValueError(
                "container carries no wrapped DEK; not an envelope/PQC "
                "upload (use download_decrypted with the BYOK key instead)")
        dek = _unwrap_dek(wrapped, kek,
                          algorithm=kek_algorithm or "aes-256-gcm")
        return decrypt_per_au(out_tio_path, dek)

    # -------------------- server-side key custody (FD-1-PF-4 / PF-6)

    async def wrap_for_server(
        self,
        *,
        dek: bytes,
        kek_id: str,
    ) -> bytes:
        """Wrap a DEK under a server-controlled KEK via the daemon's
        PKCS#11-backed key custody (FD-1-PF-4 endpoint).

        Returns the wrapped DEK blob — byte-equivalent to what
        ``ttio.key_rotation._wrap_dek(dek, kek_bytes, "aes-256-gcm")``
        would produce locally if the caller had the KEK bytes (which
        they won't, since the KEK is HSM-resident).

        POSTs to ``/v1/key-custody/wrap-for-server`` using the current
        session's bearer token. The ``dek`` is base64-encoded on the
        wire; the daemon returns the wrapped blob as a base64-encoded
        ``wrapped_dek`` field in the JSON response body.

        Parameters
        ----------
        dek : bytes
            32-byte Data Encryption Key to wrap.
        kek_id : str
            Opaque identifier for the PKCS#11 key the daemon should use.

        Returns
        -------
        bytes
            Wrapped DEK blob (the daemon's AES-256-GCM ciphertext over
            the DEK, same format as a local ``_wrap_dek`` call).

        Raises
        ------
        ValueError
            If ``dek`` is not exactly 32 bytes.
        WorkbenchHttpError
            * status 401/403 — authentication failed or token lacks the
              ``key_custody.wrap`` capability.
            * status 404 — ``kek_id`` is not registered on the daemon.
            * status 409 — ``kek_id`` is on the read-only list (cannot
              be used for new wraps).
            * Any other non-200 status from the daemon.
        """
        import base64

        from ttio.workbench._http import WorkbenchHttpError, http_json

        if len(dek) != 32:
            raise ValueError(f"DEK must be 32 bytes; got {len(dek)}")
        body: dict[str, Any] = {
            "dek": base64.b64encode(dek).decode("ascii"),
            "kek_id": kek_id,
        }
        status, resp = http_json(
            "POST", self._endpoint.host, self._endpoint.port,
            "/v1/key-custody/wrap-for-server",
            scheme=self._endpoint.http_scheme,
            token=self._session.token, body=body)
        if status != 200:
            raise WorkbenchHttpError(
                f"POST /v1/key-custody/wrap-for-server failed: {status}",
                status=status, body=resp)
        wrapped_b64 = resp["wrapped_dek"]
        return base64.b64decode(wrapped_b64)

    # --------------------------------- multi-recipient variant (FD-1 Phase B)

    async def upload_encrypted_multi(
        self,
        *,
        project: str,
        container_uri: str,
        tio_path: str,
        recipients: "list[Union[EnvelopeRecipient, ServerRecipient]]",
        server_kek_id: Optional[str] = None,
        encrypt_headers: bool = False,
        resume: Optional[ResumeState] = None,
        preview: bool = False,
    ) -> UploadResult:
        """Per-AU encrypt a `.tio` with a fresh DEK, wrap that DEK under
        *each* recipient's key, and upload (FD-1 Phase B).

        One per-run DEK is generated and wrapped once per recipient.
        Each recipient is either an :class:`EnvelopeRecipient` (caller
        supplies the KEK bytes: symmetric ``aes-256-gcm`` or
        ``ml-kem-1024`` public key) or a :class:`ServerRecipient`
        (the daemon wraps the DEK via the
        ``/v1/key-custody/wrap-for-server`` endpoint so the KEK can
        be HSM-resident — see :meth:`wrap_for_server`).

        ``recipients[0]`` becomes the packet's primary (its id is
        ``""`` on the wire); the rest travel in the append-only
        trailing block. Any holder of a recipient's key recovers the
        DEK via :meth:`download_decrypted_multi`; the daemon never
        holds a key in plaintext form.

        ``server_kek_id`` is stamped into ``ProtectionMetadata`` to
        identify the primary-recipient's KEK on the daemon's
        re-processing path. If any :class:`ServerRecipient` is present
        in ``recipients``, its ``kek_id`` is used automatically — the
        caller need not pass ``server_kek_id`` separately. Passing
        both is allowed only when they are consistent; a mismatch
        raises :exc:`ValueError`.

        This is the FD-1 output shape: wrap for both a server KEK
        (re-processable) and the researcher's key (client-side
        decryptable). Preview-gated iff any recipient uses
        ``ml-kem-1024``, mirroring the server's ``opt_pqc_preview``.
        """
        import io as _io
        import os
        import shutil
        import tempfile

        from ttio.encryption_per_au import encrypt_per_au
        from ttio.key_rotation import _wrap_dek
        from ttio.transport.codec import TransportWriter
        from ttio.transport.encrypted import (
            stamp_transport_wrapped_dek,
            write_encrypted_dataset,
        )
        from ttio.workbench.pqc import ML_KEM_1024, _require_preview

        if not recipients:
            raise ValueError("upload_encrypted_multi requires >= 1 recipient")
        extra_ids = [r.recipient_id for r in recipients[1:]]
        if "" in extra_ids or len(set(extra_ids)) != len(extra_ids):
            raise ValueError(
                "additional recipient_ids must be unique and non-empty "
                "(the empty id is reserved for the primary recipient)")
        if any(isinstance(r, EnvelopeRecipient) and r.algorithm == ML_KEM_1024
               for r in recipients):
            _require_preview(preview)

        # Derive server_kek_id from the first ServerRecipient when present.
        server_recipients = [r for r in recipients
                             if isinstance(r, ServerRecipient)]
        if server_recipients:
            auto_kek_id = server_recipients[0].kek_id
            if server_kek_id is not None and server_kek_id != auto_kek_id:
                raise ValueError(
                    f"server_kek_id={server_kek_id!r} conflicts with the "
                    f"first ServerRecipient's kek_id={auto_kek_id!r}; "
                    "pass only one or ensure they are identical")
            server_kek_id = auto_kek_id

        dek = os.urandom(32)
        with tempfile.TemporaryDirectory() as d:
            enc_tio = os.path.join(d, "enc.tio")
            shutil.copyfile(tio_path, enc_tio)
            encrypt_per_au(enc_tio, dek, encrypt_headers=encrypt_headers)

            primary = recipients[0]
            if isinstance(primary, ServerRecipient):
                primary_wrapped = await self.wrap_for_server(
                    dek=dek, kek_id=primary.kek_id)
                primary_algorithm = primary.algorithm
            else:
                primary_wrapped = _wrap_dek(dek, primary.key,
                                            algorithm=primary.algorithm)
                primary_algorithm = primary.algorithm

            additional = []
            for r in recipients[1:]:
                if isinstance(r, ServerRecipient):
                    wrapped = await self.wrap_for_server(
                        dek=dek, kek_id=r.kek_id)
                    additional.append((r.recipient_id, r.algorithm, wrapped))
                else:
                    additional.append(
                        (r.recipient_id, r.algorithm,
                         _wrap_dek(dek, r.key, algorithm=r.algorithm)))

            stamp_transport_wrapped_dek(
                enc_tio, primary_wrapped, primary_algorithm,
                additional_recipients=additional, server_kek_id=server_kek_id)
            stream = _io.BytesIO()
            with TransportWriter(stream) as tw:
                write_encrypted_dataset(tw, enc_tio)
            tis = stream.getvalue()

        return await self.upload_bytes(
            project=project, container_uri=container_uri,
            data=tis, resume=resume)

    async def download_decrypted_multi(
        self,
        *,
        container_uri: str,
        key: bytes,
        out_tio_path: str,
        recipient_id: str = "",
        preview: bool = False,
        filters: Optional[FilterDict] = None,
        max_au: int = 0,
    ):
        """Download a multi-recipient encrypted container and decrypt it
        using the recipient entry the caller holds a key for (FD-1 Phase B).

        ``recipient_id`` selects the entry to unwrap: ``""`` (the default)
        is the primary (e.g. the server KEK); pass the label given at
        upload (e.g. ``"researcher"``) for an additional recipient. ``key``
        is the matching symmetric KEK or ML-KEM-1024 private key.
        Counterpart to :meth:`upload_encrypted_multi`.
        """
        import io as _io

        from ttio.encryption_per_au import decrypt_per_au
        from ttio.key_rotation import _unwrap_dek
        from ttio.transport.encrypted import (
            read_encrypted_to_file,
            read_transport_recipients,
        )
        from ttio.workbench.pqc import ML_KEM_1024, _require_preview

        dl = await self.download_bytes(
            container_uri=container_uri, filters=filters, max_au=max_au)
        read_encrypted_to_file(_io.BytesIO(dl.payload), out_tio_path)
        recipients = read_transport_recipients(out_tio_path)
        if not recipients:
            raise ValueError(
                "container carries no wrapped DEK; not an envelope/PQC "
                "upload (use download_decrypted with the BYOK key instead)")
        match = next((r for r in recipients if r[0] == recipient_id), None)
        if match is None:
            available = ", ".join(repr(r[0]) for r in recipients)
            raise ValueError(
                f"no recipient with id {recipient_id!r} in container "
                f"(available ids: {available})")
        _rid, kek_algorithm, wrapped = match
        if kek_algorithm == ML_KEM_1024:
            _require_preview(preview)
        dek = _unwrap_dek(wrapped, key,
                          algorithm=kek_algorithm or "aes-256-gcm")
        return decrypt_per_au(out_tio_path, dek)

    # ----------------------------------------------- control plane (W3)

    def query(self, query) -> "CohortResult":  # noqa: F821 -- forward ref
        """Run a cohort query against the workbench control plane.

        POSTs to ``/v1/cohorts/query`` with the session's bearer
        token and parses the JSON reply into a :class:`CohortResult`.

        Parameters
        ----------
        query : CohortQuery or dict
            A :class:`CohortQuery` instance, or a dict already in the
            server's JSON request shape.

        Returns
        -------
        CohortResult

        Raises
        ------
        WorkbenchHttpError
            If the server returns a non-200 status code.
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
        """Return the predicted row count for a cohort query.

        POSTs to ``/v1/cohorts/preview-count`` and returns the
        server's ``count`` field. Lets the GUI / CLI show "this will
        return N rows" before committing to a full :meth:`query`.

        Parameters
        ----------
        query : CohortQuery or dict
            Same shape accepted by :meth:`query`.

        Returns
        -------
        int
            Predicted row count (``0`` when the field is absent).

        Raises
        ------
        WorkbenchHttpError
            On non-200 responses.
        """
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
        """Return a :class:`ContainersClient` bound to this session.

        The returned client exposes the ``/v1/containers`` REST
        surface (list, fetch metadata, delete). Each call constructs
        a fresh client; there is no shared state to manage.
        """
        from ttio.workbench.containers import ContainersClient
        return ContainersClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def pipelines(self):
        """Return a :class:`PipelinesClient` bound to this session.

        Exposes the ``/v1/pipelines`` REST surface (list available
        pipelines, fetch pipeline definitions). Used by the GUI's
        pipeline picker and by :meth:`submit_pipeline`.
        """
        from ttio.workbench.pipeline import PipelinesClient
        return PipelinesClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def submit_pipeline(self, *, pipeline_id: str,
                          inputs, params=None):
        """Submit a pipeline job and return its handle.

        Convenience over :meth:`jobs` for the common
        single-pipeline-submit case. For richer control (status
        filtering on list, SSE long-poll for completion), call
        :meth:`jobs` and drive the :class:`JobsClient` directly.

        Parameters
        ----------
        pipeline_id : str
            Identifier of the registered pipeline to run.
        inputs : Any
            Input specification accepted by the pipeline (usually a
            list or dict of container URIs).
        params : Any, optional
            Pipeline parameter overrides.

        Returns
        -------
        Job
        """
        return self.jobs().submit(
            pipeline_id=pipeline_id, inputs=inputs, params=params)

    def jobs(self):
        """Return a :class:`JobsClient` bound to this session.

        Exposes the ``/v1/jobs`` REST surface (submit, list, fetch,
        cancel, SSE long-poll for status).
        """
        from ttio.workbench.jobs import JobsClient
        return JobsClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def sessions(self):
        """Return a :class:`SessionsClient` bound to this session.

        Exposes the ``/v1/sessions`` REST surface (start, list,
        attach to, terminate interactive analysis sessions).
        """
        from ttio.workbench.sessions import SessionsClient
        return SessionsClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def federation(self):
        """Return a :class:`FederationClient` bound to this session.

        Exposes the federation peer list / health endpoints. The
        client degrades gracefully against a single-node server: an
        empty peer list rather than an error.
        """
        from ttio.workbench.federation import FederationClient
        return FederationClient(
            self._endpoint.host, self._endpoint.port,
            scheme=self._endpoint.http_scheme, token=self._session.token)

    def session_create(self, *, project: str, engine_pin: str,
                         image=None, command=None, env=None,
                         bind_mounts=None,
                         container_storage_root=None):
        """Create a new interactive analysis session.

        Convenience over :meth:`sessions`: POSTs ``/v1/sessions``
        with the given project + engine + container spec and returns
        a :class:`Session` handle in ``starting`` state.

        Parameters
        ----------
        project : str
            Project the session belongs to.
        engine_pin : str
            Pinned engine version identifier the session must run.
        image : str, optional
            Container image override.
        command : list of str, optional
            Custom entry-point command.
        env : dict, optional
            Environment variables to inject.
        bind_mounts : list, optional
            Bind-mount specifications passed through to the runtime.
        container_storage_root : str, optional
            Root path for the session's storage volume.

        Returns
        -------
        Session
            Handle in ``starting`` state; poll via the sessions
            client for readiness.
        """
        return self.sessions().create(
            project=project, engine_pin=engine_pin,
            image=image, command=command, env=env,
            bind_mounts=bind_mounts,
            container_storage_root=container_storage_root,
        )

    def session_proxy(self, session_id: str, *, path: str = "/"):
        """Return an unopened :class:`SessionProxyAttach` for a session.

        The proxy lets the caller open a WebSocket directly to the
        running session (e.g. for JupyterLab attach). The caller
        drives ``async with`` to open the connection.

        Parameters
        ----------
        session_id : str
            Identifier of the running session.
        path : str, optional
            Path prefix forwarded into the session's HTTP server.
            Default ``"/"``.

        Returns
        -------
        SessionProxyAttach
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
