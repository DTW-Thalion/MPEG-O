"""Python profiling harness for MPEG-O write+read hot paths.

Workload: 10K spectra × 16 peaks, HDF5 backend. Matches the Java
StressTest and ObjC TestStress workloads so results are comparable.

Uses ``SpectralDataset.write_minimal`` (Python's fast path for bulk
writes — takes pre-flattened channel arrays). For strict symmetry
with ObjC's per-spectrum write path, we also offer
``--path=spectrum-objects`` which builds 10K MassSpectrum objects.

Usage:
    python3 tools/perf/profile_python.py [--n 10000] [--peaks 16]
"""
from __future__ import annotations

import argparse
import cProfile
import io
import pstats
import sys
import time
from pathlib import Path

import numpy as np

from mpeg_o import SpectralDataset
from mpeg_o.enums import Precision, Compression
from mpeg_o.encoding_spec import ByteOrder, EncodingSpec
from mpeg_o.signal_array import SignalArray

# write_minimal uses WrittenRun; import from the fixtures helper.
sys.path.insert(0, str(Path(__file__).resolve().parents[1].parent / "python" / "tests"))
from fixtures.generate import WrittenRun  # type: ignore[import-not-found]


def build_written_run(n: int, peaks: int) -> WrittenRun:
    mz_template = np.linspace(100.0, 1000.0, peaks, dtype=np.float64)
    mz = np.tile(mz_template, n)
    intensity = (1000.0 + ((np.arange(n * peaks) * 31) % 1000)).astype(np.float64)
    offsets = (np.arange(n, dtype=np.uint64) * peaks)
    lengths = np.full(n, peaks, dtype=np.uint32)
    rts = (np.arange(n, dtype=np.float64) * 0.06)
    ms_levels = np.ones(n, dtype=np.int32)
    polarities = np.ones(n, dtype=np.int32)
    precursor_mzs = np.zeros(n, dtype=np.float64)
    precursor_charges = np.zeros(n, dtype=np.int32)
    base_peak_intensities = intensity.reshape(n, peaks).max(axis=1)
    return WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=rts,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=precursor_mzs,
        precursor_charges=precursor_charges,
        base_peak_intensities=base_peak_intensities,
    )


def workload(path: Path, n: int, peaks: int, timings: dict[str, float]) -> None:
    t0 = time.perf_counter()
    run = build_written_run(n, peaks)
    timings["build"] = time.perf_counter() - t0

    t0 = time.perf_counter()
    SpectralDataset.write_minimal(
        path,
        title="stress",
        isa_investigation_id="ISA-STRESS",
        runs={"r": run},
    )
    timings["write"] = time.perf_counter() - t0

    t0 = time.perf_counter()
    with SpectralDataset.open(path) as back:
        back_run = back.ms_runs["r"]
        assert len(back_run) == n
        sampled = 0
        for i in range(0, n, 100):
            spec = back_run[i]
            sampled += spec.signal_arrays["mz"].data.size
    timings["read"] = time.perf_counter() - t0
    expected = ((n + 99) // 100) * peaks
    assert sampled == expected, f"sampled={sampled}, expected={expected}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=10000)
    ap.add_argument("--peaks", type=int, default=16)
    ap.add_argument("--out", type=Path, default=Path("/tmp/mpgo_profile_python"))
    ap.add_argument("--warmups", type=int, default=1)
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)

    # Warm up — JIT doesn't apply, but caches and imports do.
    for _ in range(args.warmups):
        wpath = args.out / "warmup.mpgo"
        if wpath.exists():
            wpath.unlink()
        workload(wpath, args.n, args.peaks, {})
        wpath.unlink()

    mpgo_path = args.out / "stress.mpgo"
    if mpgo_path.exists():
        mpgo_path.unlink()

    timings: dict[str, float] = {}
    profiler = cProfile.Profile()
    profiler.enable()
    workload(mpgo_path, args.n, args.peaks, timings)
    profiler.disable()

    size_mb = mpgo_path.stat().st_size / 1e6
    print("=" * 78)
    print(f"Python profile: n={args.n}, peaks={args.peaks}, file={size_mb:.2f} MB")
    print("=" * 78)
    for phase, t in timings.items():
        print(f"  phase {phase:<10s}: {t*1000:8.1f} ms")
    total = sum(timings.values())
    print(f"  phase {'TOTAL':<10s}: {total*1000:8.1f} ms")
    print()

    stream = io.StringIO()
    stats = pstats.Stats(profiler, stream=stream)

    print("=" * 78)
    print("Top 30 by cumulative time:")
    print("=" * 78)
    stream.truncate(0); stream.seek(0)
    stats.sort_stats("cumulative").print_stats(30)
    print(stream.getvalue())

    print("=" * 78)
    print("Top 30 by internal (tottime):")
    print("=" * 78)
    stream.truncate(0); stream.seek(0)
    stats.sort_stats("tottime").print_stats(30)
    print(stream.getvalue())

    dump_path = args.out / "python.prof"
    stats.dump_stats(str(dump_path))
    print(f"pstats binary dumped to {dump_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
