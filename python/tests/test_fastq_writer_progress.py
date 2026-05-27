"""ProgressSink coverage for :meth:`FastqWriter.write`."""
from __future__ import annotations

from pathlib import Path

from ttio.exporters.fastq import PROGRESS_INTERVAL_READS, FastqWriter
from ttio.importers.fastq import FastqReader


def _build_fastq(path: Path, n: int) -> None:
    lines = []
    for i in range(n):
        lines.append(f"@read_{i}")
        lines.append("ACGTACGT")
        lines.append("+")
        lines.append("IIIIIIII")
    path.write_text("\n".join(lines) + "\n")


def test_fastq_writer_progress_fires(tmp_path: Path) -> None:
    n = 5000
    src = tmp_path / "in.fq"
    out = tmp_path / "out.fq"
    _build_fastq(src, n)
    run = FastqReader(src).read()

    events: list[tuple[int, int]] = []
    FastqWriter.write(
        run, out, progress=lambda d, t: events.append((d, t)),
    )
    assert len(events) >= n // PROGRESS_INTERVAL_READS, events
    assert events[-1] == (n, n)
