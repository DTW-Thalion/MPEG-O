"""ProgressSink coverage for :meth:`BamReader.to_genomic_run`.

Builds a synthetic SAM with 5000 unmapped reads and verifies:
- mid-parse callbacks fire every PROGRESS_INTERVAL_READS reads with total=-1
- final callback reports (n, n)

samtools subprocess doesn't pre-count so total stays -1 mid-parse.
"""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("samtools") is None,
    reason="samtools not installed; BAM progress test requires it on PATH",
)

from ttio.importers.bam import PROGRESS_INTERVAL_READS, BamReader  # noqa: E402


def _build_sam(path: Path, n: int) -> None:
    lines = ["@HD\tVN:1.6\tSO:unsorted", "@SQ\tSN:chr1\tLN:1000"]
    for i in range(n):
        # qname flag rname pos mapq cigar rnext pnext tlen seq qual
        lines.append(
            f"r{i:06d}\t4\t*\t0\t0\t*\t*\t0\t0\tACGTACGT\tIIIIIIII"
        )
    path.write_text("\n".join(lines) + "\n")


def test_bam_progress_fires_with_total_minus_one(tmp_path: Path) -> None:
    n = 5000
    sam = tmp_path / "synth.sam"
    _build_sam(sam, n)

    events: list[tuple[int, int]] = []
    BamReader(sam).to_genomic_run(progress=lambda d, t: events.append((d, t)))

    assert len(events) >= n // PROGRESS_INTERVAL_READS, events
    # Mid-parse fires must have total=-1 (samtools doesn't pre-count)
    assert all(t == -1 for _, t in events[:-1])
    # Final fire reports true total
    assert events[-1] == (n, n)


def test_bam_progress_none_safe(tmp_path: Path) -> None:
    sam = tmp_path / "tiny.sam"
    _build_sam(sam, 10)
    run = BamReader(sam).to_genomic_run()
    assert len(run.read_names) == 10
