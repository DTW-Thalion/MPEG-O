"""``Streamable`` — sequential access with explicit positioning."""
from __future__ import annotations

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class Streamable(Protocol):
    """Capability for sequential access with explicit positioning.

    Enables efficient iteration over large datasets without
    materializing the entire collection in memory.

    Methods
    -------
    next_object()
        Return the next element and advance the cursor.
    has_more()
        Return ``True`` if ``next_object`` can be called.
    current_position()
        Return the 0-based position of the next element to be yielded.
    seek_to_position(position)
        Reposition the cursor. Returns ``True`` on success.
    reset()
        Reposition the cursor to 0.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOStreamable`` ·
    Java: ``com.dtwthalion.mpgo.protocols.Streamable``
    """

    def next_object(self) -> Any: ...
    def has_more(self) -> bool: ...
    def current_position(self) -> int: ...
    def seek_to_position(self, position: int) -> bool: ...
    def reset(self) -> None: ...
