"""ProgressSink coverage for :func:`ttio.exporters.mztab.write`."""
from __future__ import annotations

from pathlib import Path

from ttio.exporters.mztab import PROGRESS_INTERVAL_ROWS, write
from ttio.identification import Identification


def test_mztab_writer_progress(tmp_path: Path) -> None:
    n = 1200
    idents = [
        Identification(
            run_name="run1", spectrum_index=i,
            chemical_entity=f"P{i:06d}",
            confidence_score=0.9, evidence_chain=[],
        )
        for i in range(n)
    ]
    out = tmp_path / "out.mzTab"
    events: list[tuple[int, int]] = []
    write(
        out,
        identifications=idents,
        progress=lambda d, t: events.append((d, t)),
    )
    assert len(events) >= n // PROGRESS_INTERVAL_ROWS, events
    assert events[-1] == (n, n)
