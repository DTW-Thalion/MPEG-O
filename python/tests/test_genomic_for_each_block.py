"""``GenomicRun.for_each_block``: one call per decoded block, on the pool.

The contract is weaker than :meth:`iter_reads` by exactly one thing —
blocks arrive in no order and on several threads — so what has to hold
is that every read is delivered exactly once whatever the thread count,
and that the ranges handed over tile the requested span without gaps or
overlaps. Java: ``GenomicRunBlocksTest``; Objective-C:
``TestGenomicRun`` block-iteration cases.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import threading

import pytest

from ttio.spectral_dataset import SpectralDataset
from ttio.tools import genomic_read_bench as grb


@pytest.fixture(scope="module")
def run_path(tmp_path_factory):
    p = tmp_path_factory.mktemp("feb") / "b.tio"
    assert grb.main(["make", str(p), "600", "40", "100"]) == 0
    return p


def _collect(path, threads, start=0, stop=None):
    """Every (index, quality-length) pair the callback delivers, plus the
    block ranges, gathered under a lock because the callback is called
    from several threads."""
    lock = threading.Lock()
    seen: list[tuple[int, int]] = []
    ranges: list[tuple[int, int]] = []
    with SpectralDataset.open(str(path)) as ds:
        g = ds.genomic_runs["run"]
        def fn(view, first, n):
            local = [(first + k, len(view[k].qualities)) for k in range(n)]
            with lock:
                seen.extend(local)
                ranges.append((first, n))
        g.for_each_block(fn, start, stop, threads=threads)
    return seen, ranges


def test_every_read_exactly_once_at_every_thread_count(run_path):
    for threads in (1, 2, 3, 8):
        seen, _ = _collect(run_path, threads)
        idx = sorted(i for i, _ in seen)
        assert idx == list(range(600)), f"threads={threads}"
        assert all(q == 40 for _, q in seen), f"threads={threads}"


def test_block_ranges_tile_the_span_without_gaps(run_path):
    _, ranges = _collect(run_path, 8)
    ranges.sort()
    assert ranges[0][0] == 0
    covered = 0
    for first, n in ranges:
        assert first == covered, f"gap or overlap at {first}"
        covered += n
    assert covered == 600


def test_a_sub_range_delivers_only_that_range(run_path):
    seen, ranges = _collect(run_path, 4, start=150, stop=450)
    idx = sorted(i for i, _ in seen)
    assert idx == list(range(150, 450))
    assert all(first >= 150 and first + n <= 450 for first, n in ranges)


def test_matches_iter_reads(run_path):
    """The ordering is what differs; the contents are not."""
    seen, _ = _collect(run_path, 8)
    by_index = dict(seen)
    with SpectralDataset.open(str(run_path)) as ds:
        g = ds.genomic_runs["run"]
        serial = {i: len(r.qualities) for i, r in enumerate(g.iter_reads())}
    assert by_index == serial


def test_empty_range_calls_nothing(run_path):
    seen, ranges = _collect(run_path, 4, start=200, stop=200)
    assert seen == [] and ranges == []


def test_window_is_capped_by_the_memory_budget(run_path, monkeypatch):
    """The window is a memory setting: a budget small enough to admit one
    block at a time still delivers every read."""
    monkeypatch.setenv("TTIO_MEMORY_BUDGET", str(1 << 20))
    seen, _ = _collect(run_path, 8)
    assert sorted(i for i, _ in seen) == list(range(600))


def test_block_window_shrinks_as_the_budget_does(run_path, monkeypatch):
    with SpectralDataset.open(str(run_path)) as ds:
        g = ds.genomic_runs["run"]
        b_last = g.block_count - 1
        monkeypatch.setenv("TTIO_MEMORY_BUDGET", str(1 << 40))
        wide = g._block_window(8, 0, b_last)
        monkeypatch.setenv("TTIO_MEMORY_BUDGET", str(1 << 10))
        narrow = g._block_window(8, 0, b_last)
    assert narrow == 1 and wide >= narrow
