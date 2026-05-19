"""
ttio.workbench.sessions -- interactive-session client (W4 placeholder).

W4 ships `client.session_create(engine, command, env, bind_mounts,
project)` returning a `Session` handle with `.attach_url`,
`.terminate()`, plus a `SessionProxy.attach(token)` helper that
opens the `/v1/sessions/{id}/` WS and pumps stdin/stdout against
a user-supplied byte-stream pair.
"""

from __future__ import annotations

from ttio.workbench.cohort import _not_yet_implemented


class InteractiveSession:
    """Interactive-session handle. **W4 placeholder.**"""

    def __init__(self, *args, **kwargs):
        _not_yet_implemented("InteractiveSession", "W4")


class SessionProxy:
    """WS-proxy attach helper. **W4 placeholder.**"""

    def __init__(self, *args, **kwargs):
        _not_yet_implemented("SessionProxy", "W4")
