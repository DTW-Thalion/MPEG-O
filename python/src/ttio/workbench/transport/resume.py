"""
`ResumeState` -- the small immutable record the client passes
back to `UploadClient` when re-attempting after a connection drop.

The daemon writes its side of the resume state to the
`upload_handles` table (TTIOWBWsUploadSession.m:154-159) and echoes
it back in the post-handshake ack as the `au_sequence` field. The
client's job is to retain the `resume_handle` (issued in the *first*
attempt's initial ack) plus the highest `au_sequence` it observed
in the per-AU acks, so the second-attempt handshake can quote
them both.
"""

from __future__ import annotations

import dataclasses


@dataclasses.dataclass(frozen=True)
class ResumeState:
    """Resume bookkeeping for a partial upload.

    Args:
        resume_handle: opaque server-issued handle (e.g.
            `"stg-7f9e2a14-..."`). The daemon retains this for
            24 hours after the last activity (configurable via
            `staging.retention_hours` in `server.json`); after that
            window the handle is garbage-collected and the resume
            attempt will fail with a 1002 close.
        last_acked_au_sequence: highest `au_sequence` the client
            observed in a per-AU ack during the prior attempt. The
            daemon will replay from `last_acked_au_sequence + 1` --
            the client must NOT re-send AUs at or below this value.
            Convention: `-1` means "no AU was ack'd yet" (the
            handshake ack carries `au_sequence: 0` on a fresh
            upload, so this signals the difference between
            "fresh upload" and "resume from scratch").
    """

    resume_handle: str
    last_acked_au_sequence: int = -1
