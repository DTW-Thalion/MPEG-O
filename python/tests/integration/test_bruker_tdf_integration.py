"""Bruker TDF .d → .mpgo integration test (v0.9 M58).

Distinct from the existing ``tests/test_bruker_tdf.py`` (which covers
metadata-only paths and the optional real-fixture round-trip). This
file pins the M58 verification contract: when a real Bruker fixture
is available, the produced .mpgo must carry the inv_ion_mobility
signal channel (the v0.8 M53 addition that preserves 2-D tims
geometry per peak).
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from mpeg_o import SpectralDataset
from mpeg_o.importers import bruker_tdf


@pytest.mark.requires_opentims
def test_bruker_d_to_mpgo_preserves_ion_mobility(tmp_path: Path) -> None:
    """Bruker .d → .mpgo round-trip preserves frame count and the
    per-peak inverse ion mobility channel.

    Skipped automatically when ``opentimspy`` is not installed (per
    conftest). Also skipped when no real ``.d`` fixture is available
    via the ``MPGO_BRUKER_TDF_FIXTURE`` environment variable.
    """
    fixture_env = os.environ.get("MPGO_BRUKER_TDF_FIXTURE")
    if not fixture_env:
        pytest.skip("MPGO_BRUKER_TDF_FIXTURE not set; no real Bruker .d available")
    d = Path(fixture_env)
    if not d.is_dir():
        pytest.skip(f"MPGO_BRUKER_TDF_FIXTURE={d} not a directory")

    out = tmp_path / "tims.mpgo"
    bruker_tdf.read(d, out)
    with SpectralDataset.open(out) as ds:
        run = ds.ms_runs.get("tims_ms1")
        assert run is not None, ".mpgo missing tims_ms1 run"
        assert len(run) > 0
        first = run[0]
        assert "mz" in first.signal_arrays
        assert "intensity" in first.signal_arrays
        assert "inv_ion_mobility" in first.signal_arrays, (
            "v0.8 M53 contract: inv_ion_mobility channel must be present "
            "to preserve 2-D tims geometry per peak"
        )
        n_peaks = first.signal_arrays["mz"].data.size
        assert first.signal_arrays["inv_ion_mobility"].data.size == n_peaks
