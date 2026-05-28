"""
ttio.workbench.jobs -- pipeline-job submit + tracking client.

Wraps the workbench server's REST + SSE surface for jobs:

  POST   /v1/jobs              -- submit
  GET    /v1/jobs              -- list (project-scoped, optional ?status=)
  GET    /v1/jobs/{id}         -- detail
  DELETE /v1/jobs/{id}         -- cancel (queued -> cancelled,
                                  running -> SIGTERM + cancel-grace)
  GET    /v1/jobs/{id}/events  -- SSE long-poll, raw bytes till close

Job state machine (statuses emitted on the wire):

    queued --[claim]--> starting --[spawn]--> running --[exit:0]--> completed
      |                   |                      |
      +--[cancel]-------> cancelled             +--[exit:N]--> failed
                                                 |
                                                 +--[cancel]--> cancelled

SSE wire format (per the v1.0 wire-contract survey + the reference
parser in `tti-workbench-server/scripts/smoke_jobs.py`): plain HTTP
body, no chunked encoding; the daemon streams
`event: <name>\\ndata: <json>\\n\\n` frames until close. v1.0 emits
only `job.state` events (snapshot on open + one per state
transition). No `Last-Event-Id` resumption; reconnect for a full
state replay.

Inputs dual-column contract (Decision-4 on the server): job inputs
may be either plain `container_uri` strings OR
`{"cohort_query": <query>}` dicts. The server resolves cohort
queries at submit time, stores the resolved URIs alongside the
original query verbatim so future `/resubmit` runs against the
*query*, not the snapshot.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
from typing import Any, AsyncIterator, Mapping, Optional, Union

from ttio.workbench._http import WorkbenchHttpError, http_json


# Job-input slot value: either a container URI (string) or a
# cohort-query envelope. The server's Decision-4 handler resolves
# the latter to URIs at submit time.
JobInput = Union[str, Mapping[str, Any]]


@dataclasses.dataclass(frozen=True)
class Job:
    """A pipeline job as returned by `GET /v1/jobs{,/{id}}`."""

    job_id: str
    pipeline_id: str
    status: str
    project: str
    owner: str
    queued_at: int
    started_at: Optional[int] = None
    completed_at: Optional[int] = None
    working_dir: Optional[str] = None
    engine_identifier: Optional[str] = None
    pid: Optional[int] = None
    exit_code: Optional[int] = None
    error_message: Optional[str] = None
    inputs: Mapping[str, Any] = dataclasses.field(default_factory=dict)
    params: Mapping[str, Any] = dataclasses.field(default_factory=dict)
    inputs_query: Mapping[str, Any] = dataclasses.field(default_factory=dict)

    TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled"})

    @property
    def is_terminal(self) -> bool:
        """Return True when the job has reached a terminal status.

        Returns
        -------
        bool
            True for ``completed``, ``failed``, or ``cancelled``;
            False for ``queued``, ``starting``, or ``running``.
        """
        return self.status in self.TERMINAL_STATUSES

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "Job":
        """Construct a :class:`Job` from a parsed server JSON body.

        Parameters
        ----------
        body : Mapping[str, Any]
            Decoded JSON object as returned by the ``/v1/jobs`` REST
            surface.

        Returns
        -------
        Job
            Immutable snapshot. Missing optional fields collapse to
            ``None`` / empty dict.
        """
        return cls(
            job_id=body["job_id"],
            pipeline_id=body["pipeline_id"],
            status=body["status"],
            project=body["project"],
            owner=body["owner"],
            queued_at=int(body.get("queued_at", 0)),
            started_at=_opt_int(body.get("started_at")),
            completed_at=_opt_int(body.get("completed_at")),
            working_dir=body.get("working_dir"),
            engine_identifier=body.get("engine_identifier"),
            pid=_opt_int(body.get("pid")),
            exit_code=_opt_int(body.get("exit_code")),
            error_message=body.get("error_message"),
            inputs=dict(body.get("inputs") or {}),
            params=dict(body.get("params") or {}),
            inputs_query=dict(body.get("inputs_query") or {}),
        )


def _opt_int(v: Any) -> Optional[int]:
    if v is None:
        return None
    if isinstance(v, bool):
        return None  # don't treat True/False as ints here
    if isinstance(v, (int, float)):
        return int(v)
    return None


@dataclasses.dataclass(frozen=True)
class JobEvent:
    """One SSE frame from `/v1/jobs/{id}/events`.

    v1.0 emits `event: job.state` only. Future server versions
    may add `job.heartbeat` / `job.log_line`; the parser keeps
    the raw event name + JSON data so callers can switch on it.
    """

    event: str
    data: Mapping[str, Any]


class JobsClient:
    """Job submit + tracking surface."""

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
            Bearer token (``ttiowbs_...``) used for ``Authorization``
            headers on every REST call.
        """
        self._host = host
        self._port = port
        self._scheme = scheme
        self._token = token

    def submit(
        self,
        *,
        pipeline_id: str,
        inputs: Mapping[str, JobInput],
        params: Optional[Mapping[str, Any]] = None,
    ) -> Job:
        """Submit a new pipeline job to the server queue.

        Parameters
        ----------
        pipeline_id : str
            Registered pipeline identifier (server-assigned UUID).
        inputs : Mapping[str, JobInput]
            Per-slot inputs. Each value is either a container URI
            string or a ``{"cohort_query": <query>}`` envelope built
            via :func:`build_cohort_input`.
        params : Mapping[str, Any], optional
            Free-form pipeline parameters. Not validated by v1.0.

        Returns
        -------
        Job
            The newly queued job row (status ``queued``).

        Raises
        ------
        WorkbenchHttpError
            If the server returns anything other than 201.
        """
        body: dict[str, Any] = {
            "pipeline_id": pipeline_id,
            "inputs":      dict(inputs),
        }
        if params is not None:
            body["params"] = dict(params)
        status, resp = http_json(
            "POST", self._host, self._port, "/v1/jobs",
            scheme=self._scheme, token=self._token, body=body)
        if status != 201:
            raise WorkbenchHttpError(
                f"POST /v1/jobs failed: {status}",
                status=status, body=resp)
        return Job.from_json(resp)

    def list(
        self,
        *,
        status_filter: Optional[str] = None,
        limit: Optional[int] = None,
    ) -> list[Job]:
        """List jobs visible to the caller's project scope.

        Parameters
        ----------
        status_filter : str, optional
            One of ``queued``, ``starting``, ``running``, ``completed``,
            ``failed``, ``cancelled``. When None, all states are
            returned.
        limit : int, optional
            Maximum row count. Server applies a default cap when
            None.

        Returns
        -------
        list[Job]
            Jobs ordered as the server returns them (typically
            newest-first by ``queued_at``).

        Raises
        ------
        WorkbenchHttpError
            On non-200 response.
        """
        path = "/v1/jobs"
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
        return [Job.from_json(j) for j in resp.get("jobs", [])]

    def get(self, job_id: str) -> Job:
        """Fetch a single job by identifier.

        Parameters
        ----------
        job_id : str
            Server-assigned job identifier returned by :meth:`submit`.

        Returns
        -------
        Job
            Current snapshot of the job row.

        Raises
        ------
        WorkbenchHttpError
            On non-200 response (404 when the id is unknown).
        """
        status, resp = http_json(
            "GET", self._host, self._port, f"/v1/jobs/{job_id}",
            scheme=self._scheme, token=self._token)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/jobs/{job_id} failed: {status}",
                status=status, body=resp)
        return Job.from_json(resp)

    def cancel(self, job_id: str) -> None:
        """Cancel a queued or running job.

        Parameters
        ----------
        job_id : str
            Server-assigned job identifier.

        Raises
        ------
        WorkbenchHttpError
            If the server returns anything other than 200 / 204.
            409 indicates the job is already in a terminal state.

        Notes
        -----
        Queued jobs transition directly to ``cancelled``; running
        jobs receive SIGTERM and then SIGKILL after the configured
        cancel-grace window before the row settles to ``cancelled``.
        """
        status, resp = http_json(
            "DELETE", self._host, self._port, f"/v1/jobs/{job_id}",
            scheme=self._scheme, token=self._token)
        # 204 No Content on success; 409 when already terminal.
        if status not in (200, 204):
            raise WorkbenchHttpError(
                f"DELETE /v1/jobs/{job_id} failed: {status}",
                status=status, body=resp)

    async def events(self, job_id: str) -> AsyncIterator[JobEvent]:
        """Async iterator over the job's SSE stream.

        Opens `GET /v1/jobs/{id}/events`, yields parsed `JobEvent`
        objects as they arrive. The server emits a snapshot of the
        current state on open, then one frame per state transition,
        then closes the connection when the job reaches a terminal
        state.

        Implementation: raw `asyncio.open_connection` + line-buffered
        SSE parser. Matches the reference implementation in
        `tti-workbench-server/scripts/smoke_jobs.py` byte-for-byte.
        """
        reader, writer = await asyncio.open_connection(self._host, self._port)
        try:
            req = (
                f"GET /v1/jobs/{job_id}/events HTTP/1.1\r\n"
                f"Host: {self._host}\r\n"
                f"Authorization: Bearer {self._token}\r\n"
                f"Accept: text/event-stream\r\n"
                f"Connection: keep-alive\r\n"
                f"\r\n"
            )
            writer.write(req.encode("ascii"))
            await writer.drain()

            # Read until end-of-headers.
            while True:
                line = await reader.readline()
                if line in (b"\r\n", b"", b"\n"):
                    break

            buf = b""
            current_event: Optional[str] = None
            current_data: list[str] = []
            while True:
                chunk = await reader.read(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line_bytes, buf = buf.split(b"\n", 1)
                    raw_line = line_bytes.decode(
                        "utf-8", errors="replace").rstrip("\r")
                    if raw_line.startswith("event:"):
                        current_event = raw_line[len("event:"):].strip()
                    elif raw_line.startswith("data:"):
                        current_data.append(raw_line[len("data:"):].strip())
                    elif raw_line == "":
                        if current_event or current_data:
                            try:
                                payload = (
                                    json.loads("".join(current_data))
                                    if current_data else {}
                                )
                            except json.JSONDecodeError:
                                payload = {"_raw": "".join(current_data)}
                            yield JobEvent(
                                event=current_event or "",
                                data=payload,
                            )
                            current_event = None
                            current_data = []
                    # `:` comment lines are heartbeat / no-ops.
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


def build_cohort_input(query_json: Mapping[str, Any]) -> dict[str, Any]:
    """Build the `{"cohort_query": ...}` envelope the server's
    Decision-4 input resolver recognises. Used by callers that
    want to thread a `CohortQuery` directly into a job submit
    without first running the query and pasting URIs."""
    return {"cohort_query": dict(query_json)}
