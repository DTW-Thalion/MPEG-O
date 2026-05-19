"""
ttio.workbench._http -- internal REST helper.

Shared between `cohort`, `pipeline`, and `jobs` modules. Wraps
`urllib.request` (rather than pulling in `requests` / `httpx`)
to keep the SDK's runtime dependency footprint at zero new
packages.

Not part of the public SDK surface; underscore-prefix module
signals that. Callers should use `WorkbenchClient.{query, pipelines,
jobs}()` factories rather than reaching for this directly.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Mapping, Optional


class WorkbenchHttpError(Exception):
    """Non-2xx response from a REST call.

    Carries the HTTP status + parsed body (or raw text when the body
    isn't JSON) so callers can inspect `.body.get("error")` for the
    server's `{"error": "..."}` envelope.
    """

    def __init__(self, message: str, *,
                  status: int,
                  body: Any = None):
        super().__init__(message)
        self.status = status
        self.body = body

    def error_message(self) -> Optional[str]:
        """Convenience: pull the server's `error` field if present."""
        if isinstance(self.body, Mapping):
            err = self.body.get("error")
            if isinstance(err, str):
                return err
        return None


def http_json(
    method: str,
    host: str,
    port: int,
    path: str,
    *,
    scheme: str,
    token: Optional[str] = None,
    body: Optional[Mapping[str, Any]] = None,
    timeout: float = 10.0,
) -> tuple[int, Any]:
    """Issue a JSON REST call. Returns (status, parsed_body).

    Args:
        method: `"GET"`, `"POST"`, `"DELETE"`, etc.
        host, port, scheme: server endpoint.
        path: must start with `/` (e.g. `/v1/pipelines`).
        token: bearer; sent as `Authorization: Bearer <token>` when
            non-None.
        body: optional JSON-serialisable request body. Sent compact
            (no whitespace between tokens) so the wire bytes match
            the Java port byte-for-byte.
        timeout: per-request timeout in seconds.

    Returns:
        `(status_code, parsed_body_or_text)`. Parses JSON when the
        response body looks like JSON; falls back to the raw text
        otherwise.

    Raises:
        WorkbenchHttpError: HTTP error during the request itself
            (network failure, malformed URL, etc.).
    """
    url = f"{scheme}://{host}:{port}{path}"
    headers = {"Accept": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"

    data: Optional[bytes] = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        # Compact separators so wire bytes match the Java port.
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")

    req = urllib.request.Request(
        url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            raw = resp.read()
    except urllib.error.HTTPError as e:
        # Non-2xx is still a "response" -- bubble through as
        # (status, body) so callers decide whether to raise.
        try:
            raw_text = e.read()
        except Exception:
            raw_text = b""
        return e.code, _maybe_json(raw_text)
    except (urllib.error.URLError, OSError) as e:
        raise WorkbenchHttpError(
            f"{method} {url} transport error: {e}",
            status=-1, body=None) from e

    return status, _maybe_json(raw)


def _maybe_json(raw: bytes) -> Any:
    """Decode bytes as JSON; fall back to UTF-8 text if not JSON.

    Empty bodies return `None` (e.g. 204 No Content from
    DELETE /v1/jobs/{id}).
    """
    if not raw:
        return None
    text = raw.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text
