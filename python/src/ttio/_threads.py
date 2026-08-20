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


def resolve_v6_segment_threads(pool_workers: int) -> int:
    """How many segments of one V6 block to encode at once, given how
    many blocks the writer keeps in flight.

    What the measurements say, on a 32-thread machine encoding a corpus
    with more blocks than cores: total concurrency wants to sit near the
    core count, and how it is divided between blocks and segments
    matters much less than hitting that total. 32 blocks at 1 segment
    thread and 32 at 2 came out within 2% of each other, while pushing
    the product to four times the core count cost about a quarter.

    Prefer blocks where there is a choice, because the work that is
    serial per block (building the alphabet, planning segments,
    assembling the body, deflating the read-length table) only overlaps
    across blocks. Segments are the way to use cores the blocks cannot:
    a writer near the end of a run, or one whose memory budget caps the
    blocks it can hold, has spare cores and nothing else to do with
    them. That is what the floor of 2 is for, and why the count is
    derived from the pool size rather than fixed.
    """
    cores = os.cpu_count() or 1
    workers = max(1, int(pool_workers))
    n = cores // workers
    if n < 2:
        n = 2
    if n > 8:
        n = 8
    return n


def _get_autotune() -> int:
    from .codecs.fqzcomp_nx16_z import get_autotune_threads
    return get_autotune_threads()


def _get_v6_threads() -> int:
    from .codecs.fqzcomp_nx16_z import get_v6_threads
    return get_v6_threads()


def _set_autotune(n: int) -> None:
    from .codecs.fqzcomp_nx16_z import set_autotune_threads
    set_autotune_threads(n)


def _set_v6_threads(n: int) -> None:
    from .codecs.fqzcomp_nx16_z import set_v6_threads
    set_v6_threads(n)


_lock = threading.Lock()
_depth = 0
_saved: int | None = None
_saved_v6: int | None = None


@contextlib.contextmanager
def pool_context(threads: int):
    """While a pool of more than one worker exists, the FQZCOMP auto-tune
    runs its candidates in sequence (three threads per worker would
    oversubscribe the machine), and V6 gets whatever segment threads the
    pool leaves spare. Those are different questions: auto-tune races
    three candidate encodes, so more of them per worker is waste, while
    V6 has no candidates and one thread per block would simply leave its
    segments to encode in sequence. Reference-counted across nested
    pools."""
    global _depth, _saved, _saved_v6
    if threads <= 1:
        yield
        return
    with _lock:
        if _depth == 0:
            _saved = _get_autotune()
            _set_autotune(1)
            _saved_v6 = _get_v6_threads()
            _set_v6_threads(resolve_v6_segment_threads(threads))
        _depth += 1
    try:
        yield
    finally:
        with _lock:
            _depth -= 1
            if _depth == 0:
                if _saved is not None:
                    _set_autotune(_saved)
                    _saved = None
                if _saved_v6 is not None:
                    _set_v6_threads(_saved_v6)
                    _saved_v6 = None
