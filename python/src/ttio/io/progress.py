"""ProgressSink Protocol mirroring Java's ``global.thalion.ttio.io.ProgressSink``.

Two-long progress callback. ``total == -1`` means unknown.
"""

from __future__ import annotations

from typing import Callable, Protocol, Union


class ProgressSink(Protocol):
    """Two-long progress callback. ``total == -1`` means unknown.

    Mirrors Java's ``global.thalion.ttio.io.ProgressSink``.

    Implementations should be cheap and non-blocking; they may be
    called many times per second from the worker thread. ``done`` is
    always monotonically non-decreasing within a single operation.
    Producers fire at meaningful chunk boundaries (per chromosome,
    per N reads, per spectrum) -- not per byte -- to keep the rate
    manageable.
    """

    def on_progress(self, done: int, total: int) -> None:  # pragma: no cover - Protocol
        ...


def discard() -> ProgressSink:
    """Return a ProgressSink that drops every callback.

    Use when a caller doesn't care about progress; saves a None check
    at every emit site.
    """

    class _Discard:
        def on_progress(self, done: int, total: int) -> None:
            pass

    return _Discard()


# Convenience: accept a bare callable (done, total) -> None in any place
# that takes a ProgressSink. This keeps the API ergonomic for the common
# case (caller passes ``lambda d, t: print(...)``).
ProgressSinkLike = Union[ProgressSink, Callable[[int, int], None]]


def _fire(sink: ProgressSinkLike | None, done: int, total: int) -> None:
    """Internal helper: fire on either a ProgressSink or a bare callable.

    Silently returns on ``None`` so call sites can use::

        _fire(progress, n, total)

    without a guard.
    """
    if sink is None:
        return
    fn = getattr(sink, "on_progress", None)
    if fn is not None:
        fn(done, total)
    else:
        sink(done, total)  # bare callable
