"""
Pure JSON builders + parsers for the `ttio-transport` WS subprotocol.

No I/O. The async upload + download clients import these to construct
their first frame and to interpret server replies. Tests reuse them
without standing up a daemon, and the Java port mirrors the same
shapes verbatim.

Wire shapes are defined in `tti-workbench-server/Documentation/
{upload-protocol,download-protocol,auth}.md` and confirmed in
`Source/WS/TTIOWBWsUploadSession.m` + `Source/WS/TTIOWBWsDownloadSession.m`.
"""

from __future__ import annotations

import enum
import json
from typing import Any, Mapping, Optional


# Subprotocol the daemon's libwebsockets http_mount on `/transport`
# requires. The client MUST advertise this in the WebSocket upgrade's
# `Sec-WebSocket-Protocol` header (every Python `websockets.connect`
# call needs `subprotocols=["ttio-transport"]`).
WS_SUBPROTOCOL = "ttio-transport"


def build_upload_handshake(
    *,
    owner: str,
    project: str,
    container_uri: str,
    token: Optional[str] = None,
    resume_handle: Optional[str] = None,
) -> dict[str, Any]:
    """Build the upload-mode handshake JSON.

    Per `Source/WS/TTIOWBWsUploadSession.m:205-260`, the required
    fields are `type:"handshake"`, `owner`, `project`, `container_uri`.
    `token` is required when the daemon has auth wired (i.e., in any
    real deployment). `resume_handle` switches the server into
    resumption mode.

    The function does NOT call `json.dumps` -- the caller controls
    whether to send the dict via `ws.send(json.dumps(...))` or to
    serialise it themselves (the Java port serialises through its
    own JSON library, for example).
    """
    if not owner:
        raise ValueError("upload handshake requires `owner`")
    if not project:
        raise ValueError("upload handshake requires `project`")
    if not container_uri:
        raise ValueError("upload handshake requires `container_uri`")

    out: dict[str, Any] = {
        "type":          "handshake",
        "owner":         owner,
        "project":       project,
        "container_uri": container_uri,
    }
    if token is not None:
        out["token"] = token
    if resume_handle is not None:
        out["resume_handle"] = resume_handle
    return out


# Filter keys the v1.0 download path validates. Anything else is
# either rejected by the daemon's libTTIO layer or silently dropped;
# the client-side validation here matches the server's accepted
# set and surfaces typos before the WS opens.
ALLOWED_DOWNLOAD_FILTER_KEYS = frozenset({
    "ms_level",
    "polarity",
    "retention_time_min",
    "retention_time_max",
    "precursor_mz_min",
    "precursor_mz_max",
    "precursor_charge",
    "max_au",
})


# Output-mode strings the daemon's download handshake accepts (see
# `Source/WS/TTIOWBWsDownloadHandshake.m:96-104`).
class OutputModeLiteral(str, enum.Enum):
    BINARY = "binary"
    STATS_ONLY = "stats-only"
    STATS_WITH_PAYLOAD = "stats-with-payload"


def build_download_handshake(
    *,
    container_uri: str,
    token: Optional[str] = None,
    owner: Optional[str] = None,
    output_mode: str = OutputModeLiteral.BINARY.value,
    filter: Optional[Mapping[str, Any]] = None,
    max_au: int = 0,
) -> dict[str, Any]:
    """Build the download-mode handshake JSON.

    Per `Source/WS/TTIOWBWsDownloadHandshake.m`, only `type:"handshake"`,
    `mode:"download"`, and `container_uri` are required. `output_mode`
    defaults to `"binary"` server-side too, but we pin it client-side
    so the wire is explicit. `filter` is validated against
    `ALLOWED_DOWNLOAD_FILTER_KEYS` -- unknown keys raise so the
    operator catches typos before the WS opens.

    `max_au=0` means "no AU cap"; positive integers cap the emitted
    stream to that many AUs (handy for spot-checks).
    """
    if not container_uri:
        raise ValueError("download handshake requires `container_uri`")
    if output_mode not in {m.value for m in OutputModeLiteral}:
        raise ValueError(
            f"output_mode must be one of "
            f"{sorted(m.value for m in OutputModeLiteral)}; got {output_mode!r}")
    if max_au < 0:
        raise ValueError(f"max_au must be >= 0; got {max_au}")
    if filter is not None:
        bad = set(filter.keys()) - ALLOWED_DOWNLOAD_FILTER_KEYS
        if bad:
            raise ValueError(
                f"unknown filter key(s): {sorted(bad)}; allowed: "
                f"{sorted(ALLOWED_DOWNLOAD_FILTER_KEYS)}")

    out: dict[str, Any] = {
        "type":          "handshake",
        "mode":          "download",
        "container_uri": container_uri,
        "output_mode":   output_mode,
    }
    if token is not None:
        out["token"] = token
    if owner is not None:
        out["owner"] = owner
    if max_au > 0:
        out["max_au"] = max_au
    if filter:
        out["filter"] = dict(filter)
    return out


class ServerFrameKind(str, enum.Enum):
    """Discriminator for the daemon's TEXT frames during upload + download.

    `ACK` is the per-AU acknowledgment during upload OR the initial
    post-handshake ack. `DONE` is the terminal success frame. `ERROR`
    is a server-emitted failure frame; close codes 1002 / 1011 / 1008
    follow soon after.
    """

    ACK = "ack"
    DONE = "done"
    ERROR = "error"


def parse_server_frame(raw: str | bytes) -> tuple[ServerFrameKind, dict[str, Any]]:
    """Parse a TEXT frame from the daemon into (kind, body).

    Raises `ValueError` if the body isn't valid JSON or its `type`
    field doesn't match a known frame kind. Binary frames (the
    download path's `.tis` bytes) must NOT be passed to this
    function -- the caller is responsible for dispatching by frame
    type before invoking parse.
    """
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8")
    try:
        body = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ValueError(f"server frame not JSON: {e}: {raw[:120]!r}") from e
    if not isinstance(body, dict):
        raise ValueError(f"server frame not an object: {raw[:120]!r}")
    type_field = body.get("type")
    if not isinstance(type_field, str):
        raise ValueError(f"server frame missing string `type`: {raw[:120]!r}")
    try:
        kind = ServerFrameKind(type_field)
    except ValueError as e:
        raise ValueError(
            f"unknown server frame type {type_field!r}: {raw[:120]!r}") from e
    return kind, body
