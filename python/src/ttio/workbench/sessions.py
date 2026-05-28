"""
ttio.workbench.sessions -- interactive-session client.

Wraps the workbench server's REST surface for sessions:

  POST   /v1/sessions       -- create + spawn
  GET    /v1/sessions       -- list (project-scoped, optional ?status=)
  GET    /v1/sessions/{id}  -- detail
  DELETE /v1/sessions/{id}  -- terminate (starting -> failed sync;
                                running -> SIGTERM + cancel-grace)

WS-proxy attach lives in `ttio.workbench.session_proxy`; this module
exposes the REST surface only.

Session state machine (statuses emitted on the wire):

    starting --[spawn]--> running --[exit]--> terminated
       |                    |                  | failed
       |                    |
       +--[cancel]-> failed +--[DELETE]-> terminating --> terminated

`starting` rows DO NOT count toward the `max_concurrent` cap;
`running` + `terminating` do. v1.0 server side caps to 16 by
default (config knob `sessions.max_concurrent`).

Bind-mount validation: server requires every key in `bind_mounts`
to sit under `<containerStorageRoot>/<project>/` with no `..`
sequences. The client validates the same rules ahead of POST so
operators see typos at submit time rather than at 403.
"""

from __future__ import annotations

import dataclasses
from typing import Any, Mapping, Optional, Sequence

from ttio.workbench._http import WorkbenchHttpError, http_json


# Shared "available in milestone X" raiser; W4 still uses cohort.py's
# helper for the legacy paths but new code raises typed exceptions.
from ttio.workbench.cohort import _not_yet_implemented  # noqa: F401


SESSION_STATUSES = frozenset({
    "starting", "running", "terminating", "terminated", "failed",
})

TERMINAL_SESSION_STATUSES = frozenset({"terminated", "failed"})


@dataclasses.dataclass(frozen=True)
class Session:
    """A session as returned by `GET /v1/sessions{,/{id}}`.

    Fields mirror `Source/HTTP/handlers/TTIOWBSessionsHandler.m`'s
    `_sessionToJson:` output. Fields that the server emits only
    when non-null come through as `None` in the dataclass.
    """

    session_id: str
    status: str
    project: str
    owner: str
    engine_identifier: str
    started_at: int

    # Runtime fields, populated once the session leaves `starting`:
    host_port: Optional[int] = None
    pid: Optional[int] = None
    container_id: Optional[str] = None
    working_dir: Optional[str] = None
    ready_at: Optional[int] = None
    last_seen_at: Optional[int] = None
    terminated_at: Optional[int] = None
    exit_code: Optional[int] = None
    error_message: Optional[str] = None

    # Spec fields the operator supplied:
    image: Optional[str] = None
    command: Sequence[str] = ()
    env: Mapping[str, str] = dataclasses.field(default_factory=dict)
    bind_mounts: Mapping[str, str] = dataclasses.field(default_factory=dict)

    @property
    def is_terminal(self) -> bool:
        """Return True when the session has reached a terminal status.

        Returns
        -------
        bool
            True for ``terminated`` or ``failed``; False for
            ``starting``, ``running``, or ``terminating``.
        """
        return self.status in TERMINAL_SESSION_STATUSES

    @property
    def is_attachable(self) -> bool:
        """Return True when the session accepts a WS attach.

        Returns
        -------
        bool
            True only when ``status == "running"``. The server's
            session-proxy mount rejects attach in any other state.
        """
        return self.status == "running"

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "Session":
        """Construct a :class:`Session` from a parsed server JSON body.

        Parameters
        ----------
        body : Mapping[str, Any]
            Decoded JSON object from ``/v1/sessions{,/{id}}``.

        Returns
        -------
        Session
            Immutable snapshot. Optional fields not yet populated by
            the server are set to ``None`` or their empty default.
        """
        return cls(
            session_id=body["session_id"],
            status=body["status"],
            project=body["project"],
            owner=body["owner"],
            engine_identifier=body["engine_identifier"],
            started_at=int(body.get("started_at", 0)),
            host_port=_opt_int(body.get("host_port")),
            pid=_opt_int(body.get("pid")),
            container_id=body.get("container_id"),
            working_dir=body.get("working_dir"),
            ready_at=_opt_int(body.get("ready_at")),
            last_seen_at=_opt_int(body.get("last_seen_at")),
            terminated_at=_opt_int(body.get("terminated_at")),
            exit_code=_opt_int(body.get("exit_code")),
            error_message=body.get("error_message"),
            image=body.get("image"),
            command=tuple(body.get("command") or ()),
            env=dict(body.get("env") or {}),
            bind_mounts=dict(body.get("bind_mounts") or {}),
        )


def _opt_int(v: Any) -> Optional[int]:
    if v is None or isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v)
    return None


def validate_bind_mounts(
    bind_mounts: Optional[Mapping[str, str]],
    *,
    project: str,
    container_storage_root: Optional[str] = None,
) -> None:
    """Client-side mirror of the daemon's bind-mount validation.

    Server-side rules (from
    `Source/HTTP/handlers/TTIOWBSessionsHandler.m:111-144`):

      - All keys are host paths; must be absolute.
      - No `..` segments anywhere in the path.
      - When `container_storage_root` is known, keys must sit under
        `<container_storage_root>/<project>/`.

    The client can't know `container_storage_root` without an admin
    round-trip; when it's None we only check absolute + no `..`.
    The server will catch any project-scope violation with 403; we
    just front-run the obvious typos.
    """
    if not bind_mounts:
        return
    for host_path, container_path in bind_mounts.items():
        if not host_path.startswith("/"):
            raise ValueError(
                f"bind-mount host path must be absolute: {host_path!r}")
        if ".." in host_path.split("/"):
            raise ValueError(
                f"bind-mount host path contains `..`: {host_path!r}")
        if not container_path.startswith("/"):
            raise ValueError(
                f"bind-mount container path must be absolute: "
                f"{container_path!r}")
        if container_storage_root is not None:
            prefix = container_storage_root.rstrip("/") + "/" + project + "/"
            if not host_path.startswith(prefix):
                raise ValueError(
                    f"bind-mount host path {host_path!r} must sit under "
                    f"{prefix!r}")


class SessionsClient:
    """REST surface for interactive sessions."""

    def __init__(self, host: str, port: int, *, scheme: str, token: str):
        """Bind the client to a server endpoint and bearer token.

        Parameters
        ----------
        host : str
            Workbench server hostname.
        port : int
            TCP port the REST listener is bound to.
        scheme : str
            ``"http"`` or ``"https"``.
        token : str
            Bearer token (``ttiowbs_...``).
        """
        self._host = host
        self._port = port
        self._scheme = scheme
        self._token = token

    def create(
        self,
        *,
        project: str,
        engine_pin: str,
        image: Optional[str] = None,
        command: Optional[Sequence[str]] = None,
        env: Optional[Mapping[str, str]] = None,
        bind_mounts: Optional[Mapping[str, str]] = None,
        container_storage_root: Optional[str] = None,
    ) -> Session:
        """POST /v1/sessions. Returns the freshly-created session row
        (status will be `starting`; the lifecycle thread spawns
        shortly thereafter).

        Capability required server-side: `sessions.start`.

        Args:
            project: caller must be a member.
            engine_pin: `shell`, or a descriptor-loaded engine
                (`apptainer` / `podman` / etc.).
            image, command, env: engine-specific. Shell engine
                ignores `image`.
            bind_mounts: host-path -> container-path map. Validated
                client-side (absolute, no `..`); server enforces
                project-scope.
            container_storage_root: optional; when supplied, client
                validates that bind-mount host paths sit under
                `<root>/<project>/` so the operator catches typos
                before the server returns 403.
        """
        validate_bind_mounts(bind_mounts, project=project,
                              container_storage_root=container_storage_root)
        body: dict[str, Any] = {
            "project":    project,
            "engine_pin": engine_pin,
        }
        if image is not None:        body["image"] = image
        if command is not None:      body["command"] = list(command)
        if env is not None:          body["env"] = dict(env)
        if bind_mounts is not None:  body["bind_mounts"] = dict(bind_mounts)

        status, resp = http_json(
            "POST", self._host, self._port, "/v1/sessions",
            scheme=self._scheme, token=self._token, body=body)
        if status != 201:
            raise WorkbenchHttpError(
                f"POST /v1/sessions failed: {status}",
                status=status, body=resp)
        return Session.from_json(resp)

    def list(
        self,
        *,
        status_filter: Optional[str] = None,
        limit: Optional[int] = None,
    ) -> list[Session]:
        """List sessions visible to the caller's project scope.

        Parameters
        ----------
        status_filter : str, optional
            One of ``starting``, ``running``, ``terminating``,
            ``terminated``, ``failed``. When None, all states are
            returned.
        limit : int, optional
            Maximum row count.

        Returns
        -------
        list[Session]
            Sessions ordered as the server returns them.

        Raises
        ------
        WorkbenchHttpError
            On non-200 response.
        """
        path = "/v1/sessions"
        query = []
        if status_filter:
            query.append(f"status={status_filter}")
        if limit is not None:
            query.append(f"limit={limit}")
        if query:
            path += "?" + "&".join(query)
        status, resp = http_json(
            "GET", self._host, self._port, path,
            scheme=self._scheme, token=self._token)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET {path} failed: {status}",
                status=status, body=resp)
        return [Session.from_json(s) for s in resp.get("sessions", [])]

    def get(self, session_id: str) -> Session:
        """Fetch a single session by identifier.

        Parameters
        ----------
        session_id : str
            Server-assigned session identifier.

        Returns
        -------
        Session
            Current snapshot of the session row.

        Raises
        ------
        WorkbenchHttpError
            On non-200 response (404 when the id is unknown).
        """
        status, resp = http_json(
            "GET", self._host, self._port,
            f"/v1/sessions/{session_id}",
            scheme=self._scheme, token=self._token)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/sessions/{session_id} failed: {status}",
                status=status, body=resp)
        return Session.from_json(resp)

    def terminate(self, session_id: str) -> None:
        """DELETE /v1/sessions/{id}. Returns 204 No Content on
        success; 409 when the session is already terminal.

        Authorization: session owner OR `sessions.terminate.any`."""
        status, resp = http_json(
            "DELETE", self._host, self._port,
            f"/v1/sessions/{session_id}",
            scheme=self._scheme, token=self._token)
        if status not in (200, 204):
            raise WorkbenchHttpError(
                f"DELETE /v1/sessions/{session_id} failed: {status}",
                status=status, body=resp)


# Legacy stub names kept for back-compat with W2 / W3 imports that
# referenced these. New code uses `Session` + `SessionsClient`.
InteractiveSession = Session
