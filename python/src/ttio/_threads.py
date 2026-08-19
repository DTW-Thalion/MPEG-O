"""The one thread knob of the SDK.

``TTIO_THREADS`` unset or 0 means ``max(1, cpu_count - 8)``; ``1`` is the
serial path with no executor; N is the pool size. ``threads=`` on a
writer or reader overrides the environment for that object.
"""
from __future__ import annotations

import contextlib
import os
import threading


def resolve_threads(explicit: int | None = None) -> int:
    if explicit is not None and int(explicit) > 0:
        return int(explicit)
    raw = os.environ.get("TTIO_THREADS", "").strip()
    try:
        n = int(raw) if raw else 0
    except ValueError:
        n = 1
    if n <= 0:
        n = max(1, (os.cpu_count() or 1) - 8)
    return n


def resolve_memory_budget(
    explicit: int | None = None, threads: int = 1, block_bytes: int = 1
) -> int:
    """The producer/writer byte budget: explicit argument, then the
    ``TTIO_MEMORY_BUDGET`` environment variable, then
    ``max(1 GiB, min(threads * block_bytes * 16, physical_memory / 2))``.
    Matches the ObjC and Java resolvers."""
    if explicit is not None and int(explicit) > 0:
        return int(explicit)
    raw = os.environ.get("TTIO_MEMORY_BUDGET", "").strip()
    if raw:
        try:
            n = int(raw)
        except ValueError:
            n = 0
        if n > 0:
            return n
    budget = int(threads) * int(block_bytes) * 16
    try:
        phys = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
        budget = min(budget, phys // 2)
    except (ValueError, OSError, AttributeError):
        pass
    return max(1 << 30, budget)


def _get_autotune() -> int:
    from .codecs.fqzcomp_nx16_z import get_autotune_threads
    return get_autotune_threads()


def _set_autotune(n: int) -> None:
    from .codecs.fqzcomp_nx16_z import set_autotune_threads
    set_autotune_threads(n)


_lock = threading.Lock()
_depth = 0
_saved: int | None = None


@contextlib.contextmanager
def pool_context(threads: int):
    """While a pool of more than one worker exists, the FQZCOMP auto-tune
    runs its candidates in sequence (three threads per worker would
    oversubscribe the machine). Reference-counted across nested pools."""
    global _depth, _saved
    if threads <= 1:
        yield
        return
    with _lock:
        if _depth == 0:
            _saved = _get_autotune()
            _set_autotune(1)
        _depth += 1
    try:
        yield
    finally:
        with _lock:
            _depth -= 1
            if _depth == 0 and _saved is not None:
                _set_autotune(_saved)
                _saved = None
