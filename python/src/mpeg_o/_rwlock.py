"""Writer-preferring reader-writer lock (stdlib-only).

Matches the semantics of the ObjC side's ``pthread_rwlock_t`` wrapping
``MPGOHDF5File`` (M23): multiple readers may hold the lock concurrently, a
writer is exclusive, and a waiting writer blocks new readers to avoid writer
starvation.

Kept deliberately small — no timeout, no upgrade, no reentrancy tracking.
The SpectralDataset thread-safety mode is opt-in; callers that need richer
semantics can wrap this with their own bookkeeping.
"""
from __future__ import annotations

import threading
from contextlib import contextmanager
from typing import Iterator


class RWLock:
    """Writer-preferring reader-writer lock.

    Invariants:
      * ``_readers`` counts active readers.
      * ``_writer_active`` is True iff a writer holds the lock.
      * ``_writers_waiting`` counts writers blocked in ``acquire_write``.
      * New readers wait while ``_writer_active`` or ``_writers_waiting > 0``.
    """

    __slots__ = ("_cond", "_readers", "_writer_active", "_writers_waiting")

    def __init__(self) -> None:
        self._cond = threading.Condition(threading.Lock())
        self._readers = 0
        self._writer_active = False
        self._writers_waiting = 0

    def acquire_read(self) -> None:
        with self._cond:
            while self._writer_active or self._writers_waiting > 0:
                self._cond.wait()
            self._readers += 1

    def release_read(self) -> None:
        with self._cond:
            self._readers -= 1
            if self._readers == 0:
                self._cond.notify_all()

    def acquire_write(self) -> None:
        with self._cond:
            self._writers_waiting += 1
            try:
                while self._writer_active or self._readers > 0:
                    self._cond.wait()
                self._writer_active = True
            finally:
                self._writers_waiting -= 1

    def release_write(self) -> None:
        with self._cond:
            self._writer_active = False
            self._cond.notify_all()

    @contextmanager
    def read(self) -> Iterator[None]:
        self.acquire_read()
        try:
            yield
        finally:
            self.release_read()

    @contextmanager
    def write(self) -> Iterator[None]:
        self.acquire_write()
        try:
            yield
        finally:
            self.release_write()
