"""Large-file stress tests — 100K spectra (v0.9 M62).

All tests carry the ``stress`` marker so the default CI filter
skips them; the nightly cron job removes the filter and runs the
full suite.

Performance targets per HANDOFF M62 (best-effort on a typical
developer laptop — assertions log the timing if the budget is
missed rather than fail outright, since the suite must remain
useful on slow CI runners).
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset
from mpeg_o.signatures import sign_dataset
from mpeg_o.value_range import ValueRange

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import _load_fixture_module  # type: ignore[import-not-found]

_KEY = bytes(range(32))


@pytest.fixture(scope="module")
def synth_100k(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Materialise the 100K-spectrum synthetic fixture once per session."""
    generate = _load_fixture_module("generate")
    out_dir = tmp_path_factory.mktemp("synth100k")
    generate.GENERATORS["synth_100k"](out_dir)
    return out_dir / "synth_100k.mpgo"


@pytest.mark.stress
class TestLargeFile:

    def test_write_100k_spectra(self, tmp_path: Path) -> None:
        """Generate the 100K fixture inline and assert the write
        completes in a reasonable budget."""
        generate = _load_fixture_module("generate")
        t0 = time.perf_counter()
        generate.GENERATORS["synth_100k"](tmp_path)
        elapsed = time.perf_counter() - t0
        size_mb = (tmp_path / "synth_100k.mpgo").stat().st_size / 1024 / 1024
        print(f"\n[bench] write 100K spectra: {elapsed:.2f}s, {size_mb:.1f} MB")
        # Soft target: 30s. Allow 90s on slow runners.
        assert elapsed < 90.0, f"100K write took {elapsed:.2f}s — investigate"

    def test_read_100k_sequential(self, synth_100k: Path) -> None:
        t0 = time.perf_counter()
        with SpectralDataset.open(synth_100k) as ds:
            run = ds.ms_runs["run_0001"]
            assert len(run) == 100_000
            total_peaks = 0
            for i in range(0, len(run), 1000):  # sample every 1000th — full read is too slow
                spec = run[i]
                total_peaks += spec.signal_arrays["mz"].data.size
        elapsed = time.perf_counter() - t0
        print(f"\n[bench] read 100/100K sampled spectra: {elapsed:.3f}s, {total_peaks} peaks")
        assert elapsed < 60.0

    def test_random_access_100_from_100k(self, synth_100k: Path) -> None:
        rng = np.random.default_rng(42)
        indices = rng.integers(0, 100_000, size=100).tolist()
        with SpectralDataset.open(synth_100k) as ds:
            run = ds.ms_runs["run_0001"]
            t0 = time.perf_counter()
            sizes = [run[int(i)].signal_arrays["mz"].data.size for i in indices]
            elapsed = time.perf_counter() - t0
        print(f"\n[bench] random access 100/100K: {elapsed*1000:.1f}ms")
        assert all(s == 16 for s in sizes)
        # Soft target: 500ms on warm caches; 2s tolerance for cold runs.
        assert elapsed < 2.0

    def test_index_scan_100k(self, synth_100k: Path) -> None:
        with SpectralDataset.open(synth_100k) as ds:
            run = ds.ms_runs["run_0001"]
            t0 = time.perf_counter()
            ms1_indices = run.index.indices_for_ms_level(1)
            elapsed = time.perf_counter() - t0
        print(f"\n[bench] index scan 100K: {elapsed*1000:.2f}ms")
        assert len(ms1_indices) == 100_000
        # Soft target: 50ms; allow 500ms.
        assert elapsed < 0.5

    def test_rt_range_query_100k(self, synth_100k: Path) -> None:
        """RT-range query against the 100K-row index is the bread-and-
        butter operation we need to be fast."""
        with SpectralDataset.open(synth_100k) as ds:
            run = ds.ms_runs["run_0001"]
            t0 = time.perf_counter()
            hits = run.index.indices_in_retention_time_range(
                ValueRange(minimum=1000.0, maximum=2000.0)
            )
            elapsed = time.perf_counter() - t0
        print(f"\n[bench] RT-range query (1000-2000s) over 100K: {elapsed*1000:.2f}ms ({len(hits)} hits)")
        assert elapsed < 0.5
        assert hits, "RT range should return at least one spectrum"

    def test_encrypt_100k(self, synth_100k: Path, tmp_path: Path) -> None:
        # Copy the fixture so the encrypt-in-place doesn't poison
        # other tests sharing the module-scoped synth_100k.
        import shutil
        local = tmp_path / "for_encrypt.mpgo"
        shutil.copyfile(synth_100k, local)
        with SpectralDataset.open(local, writable=True) as ds:
            run = ds.ms_runs["run_0001"]
            t0 = time.perf_counter()
            run.encrypt_with_key(_KEY, level=0)
            elapsed = time.perf_counter() - t0
        print(f"\n[bench] encrypt 100K intensity bytes: {elapsed:.2f}s")
        assert elapsed < 60.0

    def test_sign_100k(self, synth_100k: Path, tmp_path: Path) -> None:
        import shutil
        local = tmp_path / "for_sign.mpgo"
        shutil.copyfile(synth_100k, local)
        with SpectralDataset.open(local, writable=True) as ds:
            sig_group = ds.ms_runs["run_0001"].group.open_group("signal_channels")
            intensity_ds = sig_group.open_dataset("intensity_values")
            t0 = time.perf_counter()
            sig = sign_dataset(intensity_ds, _KEY)
            elapsed = time.perf_counter() - t0
        print(f"\n[bench] HMAC-sign 100K intensity dataset: {elapsed*1000:.1f}ms")
        assert sig.startswith("v2:")
        assert elapsed < 30.0
