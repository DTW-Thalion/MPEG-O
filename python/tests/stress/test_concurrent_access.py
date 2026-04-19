"""Concurrent-access stress tests (v0.9 M62).

Threading-based concurrency drills for the SpectralDataset
``thread_safe`` mode. All tests carry the ``stress`` marker so the
default CI filter skips them.

Scenarios per HANDOFF M62 §"test_concurrent_access.py":

* ``test_4_readers_concurrent`` — four threads reading independent
  slices of the same fixture; no crash, correct data per worker.
* ``test_writer_blocks_readers`` — one writer thread holds the
  exclusive write lock; reader threads wait, then succeed.
* ``test_8_threads_querying_index`` — 8 threads running
  RT-range / MS-level queries against the same index; correct
  result per thread.
"""
from __future__ import annotations

import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.value_range import ValueRange

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import _load_fixture_module  # type: ignore[import-not-found]


@pytest.fixture(scope="module")
def shared_fixture(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Module-scoped 10K-spectrum fixture so the whole class shares
    one open-file handle's-worth of data."""
    n_spectra = 10_000
    n_peaks = 16
    rng = np.random.default_rng(99)
    mz = np.tile(np.linspace(100.0, 1000.0, n_peaks), n_spectra).astype(np.float64)
    intensity = rng.uniform(0.0, 1e6, size=n_spectra * n_peaks).astype(np.float64)
    run = WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n_spectra, dtype=np.uint64) * n_peaks,
        lengths=np.full(n_spectra, n_peaks, dtype=np.uint32),
        retention_times=np.linspace(0.0, 600.0, n_spectra),
        ms_levels=np.ones(n_spectra, dtype=np.int32),
        polarities=np.ones(n_spectra, dtype=np.int32),
        precursor_mzs=np.zeros(n_spectra),
        precursor_charges=np.zeros(n_spectra, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n_spectra, n_peaks).max(axis=1),
    )
    out = tmp_path_factory.mktemp("concurrent") / "shared.mpgo"
    SpectralDataset.write_minimal(
        out, title="concurrent",
        isa_investigation_id="ISA-CONCURRENT",
        runs={"run_0001": run},
    )
    return out


@pytest.mark.stress
class TestConcurrency:

    def test_4_readers_concurrent(self, shared_fixture: Path) -> None:
        """Four threads read independent index slices through a
        ``thread_safe=True`` dataset. Each worker must see the
        spectrum it asked for and report no exception."""
        with SpectralDataset.open(shared_fixture, thread_safe=True) as ds:
            run = ds.ms_runs["run_0001"]

            def worker(offset: int) -> tuple[int, list[int]]:
                with ds.read_lock():
                    return offset, [
                        run[i].signal_arrays["mz"].data.size
                        for i in range(offset, offset + 100)
                    ]

            with ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(worker, [0, 2500, 5000, 7500]))

        assert len(results) == 4
        for offset, sizes in results:
            assert all(s == 16 for s in sizes), f"worker @ {offset} saw bad sizes"

    def test_writer_blocks_readers(self, tmp_path: Path) -> None:
        """One writer thread takes the exclusive write_lock and holds
        it for 200 ms; reader threads must wait, not race in."""
        # Build a small dedicated fixture so the writer-thread close
        # doesn't poison the module-scoped fixture.
        n = 100
        n_pts = 8
        run = WrittenRun(
            spectrum_class="MPGOMassSpectrum",
            acquisition_mode=0,
            channel_data={
                "mz": np.tile(np.linspace(100.0, 200.0, n_pts), n).astype(np.float64),
                "intensity": np.tile(np.linspace(1.0, 100.0, n_pts), n).astype(np.float64),
            },
            offsets=np.arange(n, dtype=np.uint64) * n_pts,
            lengths=np.full(n, n_pts, dtype=np.uint32),
            retention_times=np.linspace(0.0, 10.0, n),
            ms_levels=np.ones(n, dtype=np.int32),
            polarities=np.zeros(n, dtype=np.int32),
            precursor_mzs=np.zeros(n),
            precursor_charges=np.zeros(n, dtype=np.int32),
            base_peak_intensities=np.full(n, 100.0),
        )
        path = tmp_path / "writer.mpgo"
        SpectralDataset.write_minimal(
            path, title="w", isa_investigation_id="ISA-W",
            runs={"run_0001": run},
        )

        with SpectralDataset.open(path, thread_safe=True) as ds:
            holding_writer = threading.Event()
            release_writer = threading.Event()
            reader_started: list[float] = []
            reader_completed: list[float] = []

            def writer() -> None:
                with ds.write_lock():
                    holding_writer.set()
                    release_writer.wait(timeout=2.0)

            def reader(idx: int) -> None:
                reader_started.append(time.perf_counter())
                with ds.read_lock():
                    _ = ds.ms_runs["run_0001"][idx]
                reader_completed.append(time.perf_counter())

            wt = threading.Thread(target=writer)
            wt.start()
            assert holding_writer.wait(timeout=1.0)

            # Spawn 4 readers — each must block on the writer's lock.
            t_kickoff = time.perf_counter()
            readers = [threading.Thread(target=reader, args=(i,)) for i in range(4)]
            for r in readers:
                r.start()
            time.sleep(0.2)  # give readers a chance to start (they should be blocked)
            assert reader_completed == [], "readers ran while writer held the lock"

            release_writer.set()
            wt.join(timeout=2.0)
            for r in readers:
                r.join(timeout=2.0)

        # Every reader must have completed at least 100 ms after kickoff
        # (the writer held the lock for 200 ms minimum).
        assert len(reader_completed) == 4
        elapsed_per_reader = [t - t_kickoff for t in reader_completed]
        assert min(elapsed_per_reader) > 0.05

    def test_8_threads_querying_index(self, shared_fixture: Path) -> None:
        """Eight threads run mixed RT-range + MS-level queries. Each
        worker's result must equal the single-threaded reference."""
        with SpectralDataset.open(shared_fixture, thread_safe=True) as ds:
            run = ds.ms_runs["run_0001"]
            # Reference results computed under the read lock once.
            with ds.read_lock():
                rt_ref = run.index.indices_in_retention_time_range(
                    ValueRange(minimum=100.0, maximum=200.0)
                )
                ms1_ref = run.index.indices_for_ms_level(1)

            def worker(_: int) -> tuple[list[int], list[int]]:
                with ds.read_lock():
                    return (
                        run.index.indices_in_retention_time_range(
                            ValueRange(minimum=100.0, maximum=200.0)
                        ),
                        run.index.indices_for_ms_level(1),
                    )

            with ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(worker, range(8)))

        for rt_w, ms1_w in results:
            assert rt_w == rt_ref
            assert ms1_w == ms1_ref
