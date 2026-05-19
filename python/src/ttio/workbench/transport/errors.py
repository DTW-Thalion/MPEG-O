"""
Typed exceptions for the workbench transport client. Lives in its
own module so `ttio.workbench.transport.{upload,download,resume}`
can import without cycling through `__init__`.
"""

from __future__ import annotations

from typing import Optional


class TransportError(Exception):
    """Base class for all workbench-transport client failures."""


class HandshakeError(TransportError):
    """The server rejected the handshake JSON.

    Carries the WS close code (1002 for malformed handshake; 1008
    for auth-policy violations; 1011 for server-side errors during
    handshake) and the error frame's free-text reason when present.
    """

    def __init__(self, message: str, *,
                  close_code: Optional[int] = None,
                  reason: Optional[str] = None):
        super().__init__(message)
        self.close_code = close_code
        self.reason = reason


class UploadError(TransportError):
    """Upload failed mid-stream (server emitted an `error` frame or
    the WS closed without `done`)."""

    def __init__(self, message: str, *,
                  close_code: Optional[int] = None,
                  reason: Optional[str] = None,
                  last_acked_au_sequence: Optional[int] = None,
                  resume_handle: Optional[str] = None):
        super().__init__(message)
        self.close_code = close_code
        self.reason = reason
        self.last_acked_au_sequence = last_acked_au_sequence
        self.resume_handle = resume_handle


class DownloadError(TransportError):
    """Download failed (server emitted an `error` frame, cross-project
    access denied, or the WS closed without `done`)."""

    def __init__(self, message: str, *,
                  close_code: Optional[int] = None,
                  reason: Optional[str] = None):
        super().__init__(message)
        self.close_code = close_code
        self.reason = reason
