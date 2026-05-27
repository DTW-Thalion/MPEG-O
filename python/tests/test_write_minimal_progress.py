"""ProgressSink coverage for :meth:`SpectralDataset.write_minimal`.

Verifies one tick per non-empty section in §5.4 order, with an
initial baseline (0, total) call.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio.identification import Identification
from ttio.provenance import ProvenanceRecord
from ttio.quantification import Quantification
from ttio.spectral_dataset import SpectralDataset, WrittenRun


def _build_run() -> WrittenRun:
    n = 3
    n_points = 2
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=0,
        channel_data={
            "mz": np.tile(np.arange(n_points, dtype=np.float64), n),
            "intensity": np.tile(np.arange(n_points, dtype=np.float64), n),
        },
        offsets=np.arange(0, n * n_points, n_points, dtype=np.uint64),
        lengths=np.full(n, n_points, dtype=np.uint32),
        retention_times=np.arange(n, dtype=np.float64),
        ms_levels=np.ones(n, dtype=np.uint8),
        polarities=np.zeros(n, dtype=np.int8),
        precursor_mzs=np.zeros(n, dtype=np.float64),
        precursor_charges=np.zeros(n, dtype=np.int32),
        base_peak_intensities=np.zeros(n, dtype=np.float64),
    )


def test_write_minimal_progress_runs_only(tmp_path: Path) -> None:
    """Only `runs` is populated -> total=1, two emits: (0,1) then (1,1)."""
    events: list[tuple[int, int]] = []
    SpectralDataset.write_minimal(
        tmp_path / "out.tio",
        title="t", isa_investigation_id="",
        runs={"run_0001": _build_run()},
        progress=lambda d, t: events.append((d, t)),
    )
    assert events[0] == (0, 1)
    assert events[-1] == (1, 1)


def test_write_minimal_progress_multiple_sections(tmp_path: Path) -> None:
    """provenance + identifications + quantifications + runs = total 4."""
    idents = [
        Identification(
            run_name="run1", spectrum_index=1,
            chemical_entity="P1", confidence_score=0.9,
            evidence_chain=[],
        ),
    ]
    quants = [
        Quantification(
            chemical_entity="P1", sample_ref="s1",
            abundance=1.0, normalization_method="",
        ),
    ]
    provs = [ProvenanceRecord(software="ttio")]
    events: list[tuple[int, int]] = []
    SpectralDataset.write_minimal(
        tmp_path / "out.tio",
        title="t", isa_investigation_id="",
        runs={"run_0001": _build_run()},
        identifications=idents,
        quantifications=quants,
        provenance=provs,
        progress=lambda d, t: events.append((d, t)),
    )
    # Baseline (0, 4), then 4 section ticks ending at (4, 4)
    assert events[0] == (0, 4)
    assert events[-1] == (4, 4)
    # Each emit's total should be 4
    assert all(t == 4 for _, t in events)
    # Done counter monotonically increases
    dones = [d for d, _ in events]
    assert dones == sorted(dones)


def test_write_minimal_progress_none_safe(tmp_path: Path) -> None:
    SpectralDataset.write_minimal(
        tmp_path / "out.tio",
        title="t", isa_investigation_id="",
        runs={"run_0001": _build_run()},
    )
