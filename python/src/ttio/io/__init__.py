"""I/O utilities for TTI-O Python (progress sinks, etc.)."""

from __future__ import annotations

from .progress import ProgressSink, ProgressSinkLike, _fire, discard

__all__ = ["ProgressSink", "ProgressSinkLike", "discard", "_fire"]
