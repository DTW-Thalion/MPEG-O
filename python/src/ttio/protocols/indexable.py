"""Indexable — O(1) random access by index, key, or range."""
from __future__ import annotations

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class Indexable(Protocol):
    """Capability for collections that support O(1) random access.

    Every conformer provides index-based access. Key-based and
    range-based access are optional; conformers that do not support
    them raise NotImplementedError.

    Methods
    -------
    object_at_index(index)
        Return the element at index (0-based).
    count()
        Return the total number of elements.
    object_for_key(key)
        Optional. Return the element associated with key or raise
        KeyError.
    objects_in_range(start, stop)
        Optional. Return the half-open slice [start, stop).

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: TTIOIndexable ·
    Java: com.dtwthalion.ttio.protocols.Indexable
    """

    def object_at_index(self, index: int) -> Any: ...
    def count(self) -> int: ...

    # Optional members
    def object_for_key(self, key: Any) -> Any: ...
    def objects_in_range(self, start: int, stop: int) -> list[Any]: ...
