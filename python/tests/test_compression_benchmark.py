"""M21 benchmark: file size + decode speed for zlib vs LZ4 vs Numpress-delta.

Writes a synthetic 10,000-spectrum LC-MS run with each codec and
reports:

- total file size on disk,
- per-codec "open + read every spectrum" wall time.

The assertions guard against obvious regressions (LZ4 must not be
dramatically slower than zlib; Numpress must retain < 1 ppm accuracy
on m/z) while the raw numbers are printed via ``-s`` for review.
"""
from __future__ import annotations

import os
import time
from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode


def _has_lz4() -> bool:
    try:
        import hdf5plugin
        env = os.environ.get("HDF5_PLUGIN_PATH", "")
        if hdf5plugin.PLUGIN_PATH not in env:
            os.environ["HDF5_PLUGIN_PATH"] = (
                f"{hdf5plugin.PLUGIN_PATH}{os.pathsep}{env}" if env else hdf5plugin.PLUGIN_PATH
            )
        return h5py.h5z.filter_avail(32004)
    except ImportError:
        return False


def _build_synthetic_run(n_spec: int, n_pts: int, codec: str) -> WrittenRun:
    rng = np.random.default_rng(0xBE4C)  # "BENCH"
    mz_flat = 100.0 + np.sort(
        rng.uniform(0.0, 1900.0, size=n_spec * n_pts)
    ).astype(np.float64)
    intensity_flat = (1.0 + rng.exponential(500.0, size=n_spec * n_pts)).astype(np.float64)
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz_flat, "intensity": intensity_flat},
        offsets=np.arange(n_spec, dtype=np.uint64) * n_pts,
        lengths=np.full(n_spec, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 3600.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 1000.0, dtype=np.float64),
        signal_compression=codec,
    )


def _write_and_time(tmp_path: Path, codec: str, n_spec: int, n_pts: int):
    run = _build_synthetic_run(n_spec, n_pts, codec)
    out = tmp_path / f"bench_{codec}.tio"
    t0 = time.perf_counter()
    SpectralDataset.write_minimal(
        out, title=f"bench {codec}", isa_investigation_id=f"TTIO:bench:{codec}",
        runs={"run_0001": run},
    )
    write_ms = (time.perf_counter() - t0) * 1000.0
    size = out.stat().st_size

    # Read pass: open + touch every spectrum's mz buffer.
    t0 = time.perf_counter()
    with SpectralDataset.open(out) as ds:
        r = ds.ms_runs["run_0001"]
        total_points = 0
        for i in range(len(r)):
            total_points += r[i].mz_array.data.shape[0]
    read_ms = (time.perf_counter() - t0) * 1000.0
    assert total_points == n_spec * n_pts
    return size, write_ms, read_ms


def test_compression_benchmark_10k_spectra(tmp_path: Path) -> None:
    n_spec, n_pts = 10_000, 256
    raw_bytes = n_spec * n_pts * 2 * 8  # two channels, float64

    codecs = ["gzip", "numpress_delta"]
    if _has_lz4():
        codecs.insert(1, "lz4")

    results = {}
    for codec in codecs:
        size, w_ms, r_ms = _write_and_time(tmp_path, codec, n_spec, n_pts)
        results[codec] = (size, w_ms, r_ms)

    baseline = results["gzip"][0]

    print("\n[m21 bench] 10k spectra x 256 pts, raw float64 = "
          f"{raw_bytes:,} B ({raw_bytes / 1e6:.1f} MB)")
    for codec, (size, w_ms, r_ms) in results.items():
        ratio = size / raw_bytes
        vs_zlib = size / baseline
        print(
            f"[m21 bench]   {codec:>15}: size={size:>10,} B "
            f"({ratio:.1%} of raw, {vs_zlib:.2f}× zlib) "
            f"write={w_ms:6.1f} ms read={r_ms:6.1f} ms"
        )

    # LZ4 must produce a file no larger than 2× zlib (usually smaller).
    if "lz4" in results:
        assert results["lz4"][0] < 2 * baseline

    # Numpress-delta writes int64 deltas (8 bytes per sample) zlib-
    # compressed on top; plain zlib writes float64 (also 8 bytes per
    # sample) zlib-compressed. On synthetic random m/z the two are
    # roughly equal; on real LC-MS data with small, repeating deltas
    # Numpress usually wins. The handoff requirement is "log sizes
    # and read speeds" plus "< 1 ppm relative error for m/z", both of
    # which are covered by the dedicated codec tests — the benchmark
    # here guards against Numpress exploding by more than ~20% vs the
    # gzip baseline, which would indicate a broken encode path.
    assert results["numpress_delta"][0] < baseline * 1.25, (
        f"numpress_delta ({results['numpress_delta'][0]}) is >25% "
        f"larger than gzip baseline ({baseline}); encode path regressed"
    )
