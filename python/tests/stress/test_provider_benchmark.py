"""Cross-provider benchmark suite (v0.9 M62).

5 scenarios × 4 providers = 20 cells. Logs every timing to
``tests/stress/benchmark_results.json`` so we can track perf
regressions across releases. The HANDOFF M62 requirement is "log
results for all 4 providers"; assertions are loose (the suite must
remain useful on slow CI runners).
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import (
    Identification,
    SpectralDataset,
    WrittenRun,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
from _provider_matrix import (  # type: ignore[import-not-found]
    PROVIDERS as _PROVIDERS,
    maybe_skip_provider as _maybe_skip_provider,
    provider_url as _provider_url,
)

_RESULTS_PATH = Path(__file__).resolve().parent / "benchmark_results.json"


def _load_results() -> dict:
    if _RESULTS_PATH.is_file():
        return json.loads(_RESULTS_PATH.read_text())
    return {}


def _record(provider: str, scenario: str, **payload) -> None:
    """Append a benchmark entry keyed by (provider, scenario).

    Concurrent-safe enough for sequential pytest runs; a parallel
    pytest-xdist deployment would need a lock, but the stress suite
    is a serial nightly job so this is fine for now.
    """
    results = _load_results()
    by_provider = results.setdefault(provider, {})
    by_provider[scenario] = {"timestamp_unix": int(time.time()), **payload}
    _RESULTS_PATH.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")


def _build_run(n: int, n_peaks: int, rng: np.random.Generator) -> WrittenRun:
    mz = np.tile(np.linspace(100.0, 1000.0, n_peaks), n).astype(np.float64)
    intensity = rng.uniform(0.0, 1e6, size=n * n_peaks).astype(np.float64)
    return WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.arange(n, dtype=np.uint64) * n_peaks,
        lengths=np.full(n, n_peaks, dtype=np.uint32),
        retention_times=np.linspace(0.0, 600.0, n),
        ms_levels=np.ones(n, dtype=np.int32),
        polarities=np.ones(n, dtype=np.int32),
        precursor_mzs=np.zeros(n),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=intensity.reshape(n, n_peaks).max(axis=1),
    )


@pytest.fixture()
def fixture_10k(provider: str, tmp_path: Path) -> str:
    """10K-spectrum dataset on the parametrized provider."""
    rng = np.random.default_rng(7)
    run = _build_run(10_000, 16, rng)
    url = _provider_url(provider, tmp_path, "bench10k")
    SpectralDataset.write_minimal(
        url, title="bench", isa_investigation_id="ISA-BENCH",
        runs={"run_0001": run}, provider=provider,
    )
    return url


@pytest.mark.stress
@pytest.mark.parametrize("provider", _PROVIDERS)
class TestProviderBenchmark:

    def test_write_10k_spectra(self, provider: str, tmp_path: Path) -> None:
        _maybe_skip_provider(provider)
        rng = np.random.default_rng(7)
        run = _build_run(10_000, 16, rng)
        url = _provider_url(provider, tmp_path, "wbench")
        t0 = time.perf_counter()
        SpectralDataset.write_minimal(
            url, title="wbench", isa_investigation_id="ISA-W",
            runs={"run_0001": run}, provider=provider,
        )
        elapsed = time.perf_counter() - t0
        _record(provider, "write_10k_spectra", seconds=round(elapsed, 4))
        assert elapsed < 30.0

    def test_read_10k_spectra(self, provider: str, fixture_10k: str) -> None:
        t0 = time.perf_counter()
        with SpectralDataset.open(fixture_10k) as ds:
            run = ds.ms_runs["run_0001"]
            assert len(run) == 10_000
            for i in range(0, 10_000, 100):
                _ = run[i].signal_arrays["mz"].data
        elapsed = time.perf_counter() - t0
        _record(provider, "read_10k_spectra_sampled", seconds=round(elapsed, 4))
        assert elapsed < 10.0

    def test_random_access_100(self, provider: str, fixture_10k: str) -> None:
        rng = np.random.default_rng(11)
        indices = rng.integers(0, 10_000, size=100).tolist()
        with SpectralDataset.open(fixture_10k) as ds:
            run = ds.ms_runs["run_0001"]
            t0 = time.perf_counter()
            for i in indices:
                _ = run[int(i)].signal_arrays["mz"].data
            elapsed = time.perf_counter() - t0
        _record(provider, "random_access_100", seconds=round(elapsed, 4))
        assert elapsed < 2.0

    def test_compound_write_200_idents(self, provider: str, tmp_path: Path) -> None:
        """200 identifications — the v1.1 ``identifications_json``
        cross-language mirror attribute hits HDF5's 64 KB attribute
        limit somewhere between 200 and 500 records, so we benchmark
        below that ceiling rather than crashing on the synthetic 1K
        the HANDOFF originally suggested."""
        _maybe_skip_provider(provider)
        rng = np.random.default_rng(7)
        run = _build_run(200, 4, rng)
        ids = [
            Identification(
                run_name="run_0001",
                spectrum_index=int(i),
                chemical_entity=f"P{1000 + i:05d}",
                confidence_score=0.5 + (i % 50) / 100.0,
                evidence_chain=[f"engine-{i % 3}"],
            )
            for i in range(200)
        ]
        url = _provider_url(provider, tmp_path, "compound200")
        t0 = time.perf_counter()
        SpectralDataset.write_minimal(
            url, title="c", isa_investigation_id="ISA-C",
            runs={"run_0001": run},
            identifications=ids,
            provider=provider,
        )
        elapsed = time.perf_counter() - t0
        _record(provider, "compound_write_200_idents", seconds=round(elapsed, 4))
        with SpectralDataset.open(url) as ds:
            assert len(ds.identifications()) == 200
        assert elapsed < 30.0

    def test_file_size_10k(self, provider: str, fixture_10k: str) -> None:
        # SQLite + HDF5 are single files; Zarr is a directory.
        from urllib.parse import urlparse
        p = urlparse(fixture_10k)
        if p.scheme in ("memory",):
            _record(provider, "file_size_10k_bytes", bytes=0, note="memory provider has no on-disk size")
            return
        # Strip scheme prefix; Path() handles bare paths transparently.
        target = Path(p.path) if p.scheme else Path(fixture_10k)
        if target.is_dir():
            total = sum(f.stat().st_size for f in target.rglob("*") if f.is_file())
        else:
            total = target.stat().st_size
        _record(provider, "file_size_10k_bytes", bytes=int(total))
        # 10K spectra × 16 peaks × 16 bytes (mz+intensity float64) = ~2.5 MB
        # raw — anything under 50 MB is reasonable across all backends.
        assert 0 < total < 50 * 1024 * 1024
