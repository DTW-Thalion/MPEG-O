"""
ttio.workbench.containers -- /v1/containers REST client.

Wraps the workbench server's container endpoint:

  GET    /v1/containers              -- paginated list
  GET    /v1/containers/{uri}        -- detail (adds size + mtime)
  GET    /v1/containers/{uri}/layers -- per-layer breakdown
  GET    /v1/containers/{uri}/manifest -- run/spectrum summary
  DELETE /v1/containers/{uri}        -- gated delete (admin / own_uploads)

Pagination: opaque base64url cursor in the response's `next_cursor`
field; pass it back via the `cursor=` query string to fetch the
next page. Page size defaults to 50, max 500.

Cross-language equivalent: Java
`global.thalion.ttio.workbench.containers.ContainersClient`.
"""

from __future__ import annotations

import dataclasses
import urllib.parse
from typing import Any, List, Mapping, Optional

from ttio.workbench._http import WorkbenchHttpError, http_json


@dataclasses.dataclass(frozen=True)
class Container:
    """A row from `GET /v1/containers`."""

    uri: str
    project: str
    owner: str
    encrypted: bool
    storage_path: str
    created_at: int
    updated_at: int

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "Container":
        return cls(
            uri=body.get("uri") or "",
            project=body.get("project") or "",
            owner=body.get("owner") or "",
            encrypted=bool(body.get("encrypted", False)),
            storage_path=body.get("storage_path") or "",
            created_at=int(body.get("created_at") or 0),
            updated_at=int(body.get("updated_at") or 0),
        )


@dataclasses.dataclass(frozen=True)
class ContainerDetail:
    """Detail row from `GET /v1/containers/{uri}` -- adds on-disk
    `size_bytes` + `modified_at` over the list shape."""

    uri: str
    project: str
    owner: str
    encrypted: bool
    storage_path: str
    created_at: int
    updated_at: int
    size_bytes: int
    modified_at: int

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "ContainerDetail":
        return cls(
            uri=body.get("uri") or "",
            project=body.get("project") or "",
            owner=body.get("owner") or "",
            encrypted=bool(body.get("encrypted", False)),
            storage_path=body.get("storage_path") or "",
            created_at=int(body.get("created_at") or 0),
            updated_at=int(body.get("updated_at") or 0),
            size_bytes=int(body.get("size_bytes") or 0),
            modified_at=int(body.get("modified_at") or 0),
        )

    def as_container(self) -> Container:
        return Container(
            uri=self.uri, project=self.project, owner=self.owner,
            encrypted=self.encrypted, storage_path=self.storage_path,
            created_at=self.created_at, updated_at=self.updated_at,
        )


@dataclasses.dataclass(frozen=True)
class ContainerListPage:
    """One page of `GET /v1/containers`."""

    containers: List[Container]
    next_cursor: Optional[str] = None

    @property
    def has_more(self) -> bool:
        return bool(self.next_cursor)

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "ContainerListPage":
        rows = [Container.from_json(r) for r in body.get("containers") or []]
        cursor = body.get("next_cursor")
        return cls(
            containers=rows,
            next_cursor=cursor if cursor else None,
        )


@dataclasses.dataclass(frozen=True)
class ContainerLayer:
    layer_type: str
    layer_path: str
    byte_size: int
    created_at: int

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "ContainerLayer":
        return cls(
            layer_type=body.get("layer_type") or "",
            layer_path=body.get("layer_path") or "",
            byte_size=int(body.get("byte_size") or 0),
            created_at=int(body.get("created_at") or 0),
        )


@dataclasses.dataclass(frozen=True)
class MsRunSummary:
    name: str
    spectrum_class: str
    acquisition_mode: int
    channel_names: List[str]
    spectrum_count: int
    ms_level_distribution: Mapping[str, int]

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "MsRunSummary":
        dist = {str(k): int(v) for k, v in
                (body.get("ms_level_distribution") or {}).items()}
        return cls(
            name=body.get("name") or "",
            spectrum_class=body.get("spectrum_class") or "",
            acquisition_mode=int(body.get("acquisition_mode") or 0),
            channel_names=list(body.get("channel_names") or []),
            spectrum_count=int(body.get("spectrum_count") or 0),
            ms_level_distribution=dist,
        )


@dataclasses.dataclass(frozen=True)
class NmrRunSummary:
    name: str
    spectrum_count: int

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "NmrRunSummary":
        return cls(
            name=body.get("name") or "",
            spectrum_count=int(body.get("spectrum_count") or 0),
        )


@dataclasses.dataclass(frozen=True)
class GenomicRunSummary:
    name: str
    read_count: int
    platform: str

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "GenomicRunSummary":
        return cls(
            name=body.get("name") or "",
            read_count=int(body.get("read_count") or 0),
            platform=body.get("platform") or "",
        )


@dataclasses.dataclass(frozen=True)
class ContainerManifest:
    """Manifest from `GET /v1/containers/{uri}/manifest`."""

    uri: str
    title: str
    isa_investigation_id: str
    ms_runs: List[MsRunSummary]
    nmr_runs: List[NmrRunSummary]
    genomic_runs: List[GenomicRunSummary]
    identification_count: int
    quantification_count: int
    provenance_record_count: int

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "ContainerManifest":
        return cls(
            uri=body.get("uri") or "",
            title=body.get("title") or "",
            isa_investigation_id=body.get("isa_investigation_id") or "",
            ms_runs=[MsRunSummary.from_json(r)
                     for r in body.get("ms_runs") or []],
            nmr_runs=[NmrRunSummary.from_json(r)
                      for r in body.get("nmr_runs") or []],
            genomic_runs=[GenomicRunSummary.from_json(r)
                          for r in body.get("genomic_runs") or []],
            identification_count=int(body.get("identification_count") or 0),
            quantification_count=int(body.get("quantification_count") or 0),
            provenance_record_count=int(body.get("provenance_record_count") or 0),
        )


class ContainersClient:
    """REST client for `/v1/containers`.

    Cross-language equivalent: Java
    `global.thalion.ttio.workbench.containers.ContainersClient`.
    """

    def __init__(self, host: str, port: int, scheme: str, token: str) -> None:
        self.host = host
        self.port = port
        self.scheme = scheme
        self.token = token

    def list(self,
              project: Optional[str] = None,
              owner: Optional[str] = None,
              limit: Optional[int] = None,
              cursor: Optional[str] = None) -> ContainerListPage:
        """`GET /v1/containers` with optional filters + pagination."""
        params = []
        if project:
            params.append(("project", project))
        if owner:
            params.append(("owner", owner))
        if limit is not None:
            params.append(("limit", str(limit)))
        if cursor:
            params.append(("cursor", cursor))
        qs = "?" + urllib.parse.urlencode(params) if params else ""
        status, body = http_json(
            "GET", self.host, self.port, "/v1/containers" + qs,
            scheme=self.scheme, token=self.token)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/containers failed: {status}",
                status=status, body=body)
        return ContainerListPage.from_json(body)

    def get(self, uri: str) -> ContainerDetail:
        """`GET /v1/containers/{uri}`."""
        path = "/v1/containers/" + _encode_path(uri)
        status, body = http_json(
            "GET", self.host, self.port, path,
            scheme=self.scheme, token=self.token)
        if status == 404:
            raise WorkbenchHttpError(
                f"container not found: {uri}", status=404, body=body)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/containers/{uri} failed: {status}",
                status=status, body=body)
        return ContainerDetail.from_json(body)

    def layers(self, uri: str) -> List[ContainerLayer]:
        """`GET /v1/containers/{uri}/layers`."""
        path = "/v1/containers/" + _encode_path(uri) + "/layers"
        status, body = http_json(
            "GET", self.host, self.port, path,
            scheme=self.scheme, token=self.token)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/containers/{uri}/layers failed: {status}",
                status=status, body=body)
        return [ContainerLayer.from_json(r) for r in body.get("layers") or []]

    def manifest(self, uri: str) -> ContainerManifest:
        """`GET /v1/containers/{uri}/manifest`."""
        path = "/v1/containers/" + _encode_path(uri) + "/manifest"
        status, body = http_json(
            "GET", self.host, self.port, path,
            scheme=self.scheme, token=self.token)
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/containers/{uri}/manifest failed: {status}",
                status=status, body=body)
        return ContainerManifest.from_json(body)

    def delete(self, uri: str) -> None:
        """`DELETE /v1/containers/{uri}` -- gated server-side."""
        path = "/v1/containers/" + _encode_path(uri)
        status, body = http_json(
            "DELETE", self.host, self.port, path,
            scheme=self.scheme, token=self.token)
        if status not in (200, 204):
            raise WorkbenchHttpError(
                f"DELETE /v1/containers/{uri} failed: {status}",
                status=status, body=body)


def _encode_path(s: str) -> str:
    """Percent-encode a URI path segment. The server's safe_uri form
    expects the URI's opaque part with `:` and `/` percent-encoded
    (space-to-%20, not the form-encoding plus)."""
    return urllib.parse.quote(s, safe="")
