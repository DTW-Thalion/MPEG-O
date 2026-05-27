"""ProgressSink coverage for :meth:`BamWriter.write`."""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("samtools") is None,
    reason="samtools not installed",
)

from ttio.exporters.bam import PROGRESS_INTERVAL_READS, BamWriter  # noqa: E402
from ttio.importers.bam import BamReader  # noqa: E402


def _build_sam(path: Path, n: int) -> None:
    lines = ["@HD\tVN:1.6\tSO:unsorted", "@SQ\tSN:chr1\tLN:1000"]
    for i in range(n):
        lines.append(
            f"r{i:06d}\t4\t*\t0\t0\t*\t*\t0\t0\tACGTACGT\tIIIIIIII"
        )
    path.write_text("\n".join(lines) + "\n")


def test_bam_writer_progress(tmp_path: Path) -> None:
    n = 5000
    sam = tmp_path / "in.sam"
    _build_sam(sam, n)
    run = BamReader(sam).to_genomic_run()

    bam = tmp_path / "out.bam"
    events: list[tuple[int, int]] = []
    BamWriter(bam).write(
        run, sort=False,
        progress=lambda d, t: events.append((d, t)),
    )
    assert len(events) >= n // PROGRESS_INTERVAL_READS
    assert events[-1] == (n, n)
