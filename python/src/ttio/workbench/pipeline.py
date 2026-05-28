"""
ttio.workbench.pipeline -- pipeline registry + submit client.

Wraps the workbench server's REST surface for pipelines:

  POST /v1/pipelines           -- register a pipeline
  GET  /v1/pipelines           -- list (project-scoped)
  GET  /v1/pipelines/{id}      -- detail

(Pipeline disable / delete is server-side `DELETE /v1/pipelines/{id}`;
not surfaced in the v1.0 client SDK -- operators manage pipelines via
direct REST. Could land in a v1.x client patch if a real workflow
needs it.)

The workbench server's pipeline registry (`TTIOWBPipelineRegistry`)
enforces `(project, identifier, version)` uniqueness; duplicate
registration returns 409. `inputs_schema` / `outputs_schema` are
free-form JSON objects; v1.0 does not validate their shape.

Capability required: `pipelines.manage` + membership of the target
project.
"""

from __future__ import annotations

import dataclasses
import json
from typing import Any, Mapping, Optional

from ttio.workbench._http import WorkbenchHttpError, http_json


@dataclasses.dataclass(frozen=True)
class Pipeline:
    """A pipeline as returned by `GET /v1/pipelines{,/{id}}`."""

    pipeline_id: str
    identifier: str
    version: str
    project: str
    owner: str
    engine_pin: Optional[str]
    definition: str
    inputs_schema: Mapping[str, Any]
    outputs_schema: Mapping[str, Any]

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "Pipeline":
        """Construct a :class:`Pipeline` from a parsed server JSON body.

        Parameters
        ----------
        body : Mapping[str, Any]
            Decoded JSON object from ``/v1/pipelines{,/{id}}``.

        Returns
        -------
        Pipeline
            Immutable snapshot. ``inputs_schema`` and
            ``outputs_schema`` are normalised to dicts even when the
            server emits them as JSON-text fields.
        """
        def _maybe_json(value: Any) -> Mapping[str, Any]:
            # Server returns these as parsed JSON; some legacy paths
            # emit them as strings (TEXT round-trip). Be tolerant.
            if isinstance(value, str):
                try:
                    return json.loads(value)
                except json.JSONDecodeError:
                    return {}
            if isinstance(value, Mapping):
                return value
            return {}

        return cls(
            pipeline_id=body["pipeline_id"],
            identifier=body["identifier"],
            version=body["version"],
            project=body["project"],
            owner=body["owner"],
            engine_pin=body.get("engine_pin"),
            definition=body.get("definition", ""),
            inputs_schema=_maybe_json(body.get("inputs_schema", {})),
            outputs_schema=_maybe_json(body.get("outputs_schema", {})),
        )


class PipelinesClient:
    """Pipeline registry surface. Constructed via
    `WorkbenchClient.pipelines()`."""

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

    def register(
        self,
        *,
        identifier: str,
        version: str,
        project: str,
        definition: str,
        engine_pin: Optional[str] = None,
        inputs_schema: Optional[Mapping[str, Any]] = None,
        outputs_schema: Optional[Mapping[str, Any]] = None,
    ) -> Pipeline:
        """Register a new pipeline with the workbench server.

        Parameters
        ----------
        identifier : str
            Human-readable pipeline identifier; unique per
            ``(project, version)``.
        version : str
            Caller-supplied version label (free-form).
        project : str
            Target project; caller must be a member.
        definition : str
            Pipeline definition body (engine-specific wire shape).
        engine_pin : str, optional
            Engine identifier the pipeline must run under
            (``shell``, ``apptainer``, ``podman``, etc.).
        inputs_schema : Mapping[str, Any], optional
            Free-form JSON object describing input slots. Not
            schema-validated by v1.0.
        outputs_schema : Mapping[str, Any], optional
            Free-form JSON object describing output slots.

        Returns
        -------
        Pipeline
            The freshly registered pipeline row.

        Raises
        ------
        WorkbenchHttpError
            If the server returns anything other than 201. 409
            indicates a duplicate ``(project, identifier, version)``.
        """
        body: dict[str, Any] = {
            "identifier":  identifier,
            "version":     version,
            "project":     project,
            "definition":  definition,
        }
        if engine_pin is not None:
            body["engine_pin"] = engine_pin
        if inputs_schema is not None:
            body["inputs_schema"] = dict(inputs_schema)
        if outputs_schema is not None:
            body["outputs_schema"] = dict(outputs_schema)
        status, resp = http_json(
            "POST", self._host, self._port, "/v1/pipelines",
            scheme=self._scheme, token=self._token, body=body)
        if status != 201:
            raise WorkbenchHttpError(
                f"POST /v1/pipelines failed: {status}",
                status=status, body=resp)
        return Pipeline.from_json(resp)

    def list(self) -> list[Pipeline]:
        """List pipelines visible to the caller's project scope.

        Returns
        -------
        list[Pipeline]
            All pipelines the caller is permitted to see.

        Raises
        ------
        WorkbenchHttpError
            On non-200 response.
        """
        status, resp = http_json(
            "GET", self._host, self._port, "/v1/pipelines",
            scheme=self._scheme, token=self._token)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/pipelines failed: {status}",
                status=status, body=resp)
        return [Pipeline.from_json(p) for p in resp.get("pipelines", [])]

    def get(self, pipeline_id: str) -> Pipeline:
        """Fetch a single pipeline by identifier.

        Parameters
        ----------
        pipeline_id : str
            Server-assigned pipeline identifier (UUID).

        Returns
        -------
        Pipeline
            The pipeline definition row.

        Raises
        ------
        WorkbenchHttpError
            On non-200 response (404 when the id is unknown).
        """
        status, resp = http_json(
            "GET", self._host, self._port,
            f"/v1/pipelines/{pipeline_id}",
            scheme=self._scheme, token=self._token)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/pipelines/{pipeline_id} failed: {status}",
                status=status, body=resp)
        return Pipeline.from_json(resp)
