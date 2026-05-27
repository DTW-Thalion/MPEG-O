"""ProgressSink coverage for :meth:`FastaReader.read_unaligned`.

Synthetic 5000-record FASTA, asserts >=5 callbacks fire and final
``(n, n)``.
"""
from __future__ import annotations

from pathlib import Path

from ttio.importers.fasta import PROGRESS_INTERVAL_READS, FastaReader


def _build_fasta(path: Path, n: int) -> None:
    lines = []
    for i in range(n):
        lines.append(f">read_{i}")
        lines.append("ACGTACGT")
    path.write_text("\n".join(lines) + "\n")


def test_fasta_unaligned_progress_fires(tmp_path: Path) -> None:
    n = 5000
    fa = tmp_path / "synth.fa"
    _build_fasta(fa, n)

    events: list[tuple[int, int]] = []
    FastaReader(fa).read_unaligned(
        progress=lambda d, t: events.append((d, t)),
    )

    assert len(events) >= n // PROGRESS_INTERVAL_READS, events
    assert events[-1] == (n, n)
    assert any(t == -1 for _, t in events[:-1])


def test_fasta_unaligned_progress_none_safe(tmp_path: Path) -> None:
    n = 50
    fa = tmp_path / "tiny.fa"
    _build_fasta(fa, n)
    run = FastaReader(fa).read_unaligned()
    assert len(run.read_names) == n
