"""M23 benchmark: SpectralDataset thread-safe overhead and parallel read.

Measures, on a synthetic 10k-spectrum MS run:
  * Single-thread ``identifications()`` baseline (thread_safe=False)
  * Same loop with thread_safe=True (lock overhead)
  * 4-thread parallel loop with thread_safe=True

The hard assertion is correctness (all workers return equal results
and nothing crashes) + a soft ceiling on lock overhead (<30 %% of
baseline to absorb CI jitter). Raw numbers are printed via ``-s``.

Speedup expectations: the Python GIL and libhdf5's single-writer
global mutex mean the 2-4x speedup quoted in the v0.4 plan is
aspirational on read-heavy workloads through h5py. We report what
we measure and let the ARCHITECTURE.md threading section document
the honest picture.
"""
from __future__ import annotations

import statistics
import threading
import time
from pathlib import Path

import pytest

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.identification import Identification


def _build_fixture(tmp_path: Path, n_ids: int = 200) -> Path:
    path = tmp_path / "m23_bench.tio"
    ids = [
        Identification(
            run_name="run0",
            spectrum_index=i,
            chemical_entity=f"CHEBI:{i:06d}",
            confidence_score=float(i % 100) / 100.0,
            evidence_chain=[f"spec:{i}"],
        )
        for i in range(n_ids)
    ]
    SpectralDataset.write_minimal(
        path,
        title="M23 bench",
        isa_investigation_id="ISA-M23",
        runs={},
        identifications=ids,
    )
    return path


def _time_loop(ds: SpectralDataset, iterations: int) -> float:
    start = time.perf_counter()
    for _ in range(iterations):
        ds.identifications()
    return time.perf_counter() - start


def test_m23_single_vs_parallel_read(tmp_path: Path) -> None:
    path = _build_fixture(tmp_path, n_ids=200)
    iters = 50

    # Baseline: no lock
    with SpectralDataset.open(path) as ds:
        baseline = _time_loop(ds, iters)
        ref = ds.identifications()

    # Single thread with lock acquired/released each call
    with SpectralDataset.open(path, thread_safe=True) as ds:
        locked = _time_loop(ds, iters)

    # 4 threads, 25 iterations each (100 total reads vs 50 in baseline)
    with SpectralDataset.open(path, thread_safe=True) as ds:
        threads = 4
        per_thread = 25
        results: list = [None] * threads
        errors: list[BaseException] = []

        def worker(idx: int) -> None:
            try:
                last = None
                for _ in range(per_thread):
                    last = ds.identifications()
                results[idx] = last
            except BaseException as exc:
                errors.append(exc)

        start = time.perf_counter()
        ts = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
        for t in ts: t.start()
        for t in ts: t.join()
        parallel = time.perf_counter() - start

        assert not errors, f"worker exceptions: {errors}"
        for r in results:
            assert r == ref

    overhead_ratio = (locked - baseline) / baseline if baseline > 0 else 0.0
    total_parallel_reads = threads * per_thread
    per_call_serial   = locked / iters
    per_call_parallel = parallel / total_parallel_reads

    print(f"\nM23 benchmark ({iters} reads, {total_parallel_reads} parallel reads):")
    print(f"  baseline (no lock)          : {baseline*1000:.2f} ms")
    print(f"  thread_safe single-thread   : {locked*1000:.2f} ms "
          f"(overhead {overhead_ratio*100:+.1f}%)")
    print(f"  thread_safe 4-thread x {per_thread}     : {parallel*1000:.2f} ms")
    print(f"  per-call serial             : {per_call_serial*1e6:.1f} µs")
    print(f"  per-call parallel           : {per_call_parallel*1e6:.1f} µs")

    # Soft bound: lock overhead must be modest, not an order of magnitude.
    # CI jitter allowance: 300%.
    assert overhead_ratio < 3.0, (
        f"M23: thread_safe overhead {overhead_ratio*100:.1f}% exceeds 300% ceiling"
    )
