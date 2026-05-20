"""
ttio.workbench.federation -- /v1/federation REST client.

Federation is a v1.1+ server feature (spec §12.3). The v1.0 server is
single-node and does **not** expose ``/v1/federation/peers``. This
client degrades gracefully: :meth:`FederationClient.peers` returns an
empty list on a 404 instead of raising, so callers can treat a v1.0
server as a single-node federation of one.

Cross-language equivalent: Java
``global.thalion.ttio.workbench.federation.FederationClient``.
"""

from __future__ import annotations

import dataclasses
from typing import Any, List, Mapping

from ttio.workbench._http import WorkbenchHttpError, http_json


@dataclasses.dataclass(frozen=True)
class Peer:
    """A federation peer node from ``GET /v1/federation/peers``."""

    peer_id: str
    url: str
    status: str

    @classmethod
    def from_json(cls, body: Mapping[str, Any]) -> "Peer":
        return cls(
            peer_id=body.get("peer_id") or body.get("id") or "",
            url=body.get("url") or "",
            status=body.get("status") or "unknown",
        )


class FederationClient:
    """Client for the workbench federation endpoint.

    Bound to a session + endpoint. Construct via
    ``WorkbenchClient.federation()``.
    """

    def __init__(self, host: str, port: int, scheme: str, token: str) -> None:
        self._host = host
        self._port = port
        self._scheme = scheme
        self._token = token

    def peers(self) -> List[Peer]:
        """List federation peers.

        Returns an empty list when the server does not expose the
        federation endpoint (HTTP 404 -- a v1.0 single-node server),
        so the caller never has to special-case version detection.
        Any other non-2xx status raises :class:`WorkbenchHttpError`.
        """
        status, body = http_json(
            "GET", self._host, self._port, "/v1/federation/peers",
            scheme=self._scheme, token=self._token)
        if status == 404:
            return []  # v1.0 single-node: federation not exposed
        if status != 200:
            raise WorkbenchHttpError(
                f"GET /v1/federation/peers failed: {status}",
                status=status, body=body)
        rows = body.get("peers") if isinstance(body, Mapping) else body
        return [Peer.from_json(r) for r in (rows or [])]

    def is_federated(self) -> bool:
        """True iff the server reports at least one federation peer.
        A v1.0 single-node server reports none."""
        return len(self.peers()) > 0
