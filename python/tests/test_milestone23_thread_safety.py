"""Milestone 23 — SpectralDataset thread-safety (opt-in RW lock).

Verifies:
  * The RWLock primitive honours writer-preferring semantics.
  * ``SpectralDataset.open(..., thread_safe=True)`` returns a dataset that
    reports ``is_thread_safe`` and serves ``read_lock``/``write_lock``.
  * Concurrent readers of ``identifications`` on a fixture dataset do not
    crash and observe the same data.
  * A writer holding ``write_lock()`` blocks a subsequent reader.
"""
from __future__ import annotations

import threading
import time
from pathlib import Path

import pytest

from mpeg_o._rwlock import RWLock
from mpeg_o.spectral_dataset import SpectralDataset


def test_rwlock_multiple_readers_can_hold_concurrently() -> None:
    lock = RWLock()
    lock.acquire_read()
    lock.acquire_read()
    # Both readers hold; a try-write via a short-lived thread should not
    # complete before we release.
    writer_done = threading.Event()

    def writer() -> None:
        lock.acquire_write()
        writer_done.set()
        lock.release_write()

    t = threading.Thread(target=writer)
    t.start()
    # Writer must NOT have completed while readers hold.
    assert not writer_done.wait(timeout=0.1)
    lock.release_read()
    lock.release_read()
    assert writer_done.wait(timeout=1.0)
    t.join()


def test_rwlock_writer_is_exclusive() -> None:
    lock = RWLock()
    lock.acquire_write()
    reader_done = threading.Event()

    def reader() -> None:
        lock.acquire_read()
        reader_done.set()
        lock.release_read()

    t = threading.Thread(target=reader)
    t.start()
    assert not reader_done.wait(timeout=0.1)
    lock.release_write()
    assert reader_done.wait(timeout=1.0)
    t.join()


def test_dataset_is_thread_safe_flag(minimal_ms_fixture: Path) -> None:
    with SpectralDataset.open(minimal_ms_fixture) as ds:
        assert ds.is_thread_safe is False
    with SpectralDataset.open(minimal_ms_fixture, thread_safe=True) as ds:
        assert ds.is_thread_safe is True


def test_concurrent_readers_on_identifications(full_ms_fixture: Path) -> None:
    """4 threads x 25 reads of identifications on a fixture dataset."""
    with SpectralDataset.open(full_ms_fixture, thread_safe=True) as ds:
        baseline = ds.identifications()
        results: list[list] = [None] * 4  # type: ignore[assignment]
        errors: list[BaseException] = []

        def worker(idx: int) -> None:
            try:
                last = None
                for _ in range(25):
                    last = ds.identifications()
                results[idx] = last
            except BaseException as exc:  # pragma: no cover
                errors.append(exc)

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors, f"worker exceptions: {errors}"
        for r in results:
            assert r == baseline


def test_writer_blocks_readers(minimal_ms_fixture: Path) -> None:
    with SpectralDataset.open(minimal_ms_fixture, thread_safe=True) as ds:
        reader_ran = threading.Event()

        def reader() -> None:
            with ds.read_lock():
                reader_ran.set()

        with ds.write_lock():
            t = threading.Thread(target=reader)
            t.start()
            # Reader should be blocked while we hold the write lock.
            blocked = not reader_ran.wait(timeout=0.1)
        # Now that the write lock is released, the reader must complete.
        t.join(timeout=1.0)
        assert blocked, "reader acquired read lock while writer held write lock"
        assert reader_ran.is_set(), "reader failed to acquire lock after writer released"
