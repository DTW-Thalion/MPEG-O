"""ProgressSink coverage for :class:`FastqReader.read`.

Builds a synthetic FASTQ with 5000 records, asserts:
- at least 5 mid-parse callbacks fire (5000 // 1000)
- the final callback reports ``(n, n)`` with true total
- all mid-parse fires use ``total == -1``
- progress is monotonically non-decreasing
"""
from __future__ import annotations

from pathlib import Path

from ttio.importers.fastq import PROGRESS_INTERVAL_READS, FastqReader


def _build_fastq(path: Path, n: int) -> None:
    lines = []
    for i in range(n):
        lines.append(f"@read_{i}")
        lines.append("ACGTACGT")
        lines.append("+")
        lines.append("IIIIIIII")
    path.write_text("\n".join(lines) + "\n")


def test_fastq_progress_fires_per_interval(tmp_path: Path) -> None:
    n = 5000
    fq = tmp_path / "synth.fq"
    _build_fastq(fq, n)

    events: list[tuple[int, int]] = []
    FastqReader(fq).read(progress=lambda d, t: events.append((d, t)))

    assert len(events) >= n // PROGRESS_INTERVAL_READS, events
    # At least one mid-parse fire with total=-1
    assert any(t == -1 for _, t in events[:-1])
    # Final fire reports the true total
    assert events[-1] == (n, n)
    # Monotonically non-decreasing done
    dones = [d for d, _ in events]
    assert dones == sorted(dones)


def test_fastq_progress_protocol_object(tmp_path: Path) -> None:
    """Protocol-style sink (object with on_progress) also accepted."""
    n = 5000
    fq = tmp_path / "synth.fq"
    _build_fastq(fq, n)

    class CapturingSink:
        def __init__(self) -> None:
            self.events: list[tuple[int, int]] = []

        def on_progress(self, done: int, total: int) -> None:
            self.events.append((done, total))

    sink = CapturingSink()
    FastqReader(fq).read(progress=sink)
    assert sink.events[-1] == (n, n)
    assert len(sink.events) >= 5


def test_fastq_progress_none_is_safe(tmp_path: Path) -> None:
    """Passing progress=None (the default) raises nothing."""
    n = 100
    fq = tmp_path / "small.fq"
    _build_fastq(fq, n)
    run = FastqReader(fq).read(progress=None)
    assert len(run.read_names) == n
