"""ProgressSink coverage for :class:`SamReader` (BamReader subclass).

Verifies SamReader inherits progress= and behaves identically.
"""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("samtools") is None,
    reason="samtools not installed; SAM progress test requires it on PATH",
)

from ttio.importers.bam import PROGRESS_INTERVAL_READS  # noqa: E402
from ttio.importers.sam import SamReader  # noqa: E402


def _build_sam(path: Path, n: int) -> None:
    lines = ["@HD\tVN:1.6\tSO:unsorted", "@SQ\tSN:chr1\tLN:1000"]
    for i in range(n):
        lines.append(
            f"r{i:06d}\t4\t*\t0\t0\t*\t*\t0\t0\tACGTACGT\tIIIIIIII"
        )
    path.write_text("\n".join(lines) + "\n")


def test_sam_reader_inherits_progress(tmp_path: Path) -> None:
    n = 5000
    sam = tmp_path / "synth.sam"
    _build_sam(sam, n)

    events: list[tuple[int, int]] = []
    SamReader(sam).to_genomic_run(progress=lambda d, t: events.append((d, t)))

    assert len(events) >= n // PROGRESS_INTERVAL_READS
    assert events[-1] == (n, n)
