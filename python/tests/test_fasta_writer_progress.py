"""ProgressSink coverage for :meth:`FastaWriter.write_run` and
:meth:`FastaWriter.write_reference`.
"""
from __future__ import annotations

from pathlib import Path

from ttio.exporters.fasta import PROGRESS_INTERVAL_READS, FastaWriter
from ttio.genomic.reference_import import ReferenceImport
from ttio.importers.fasta import FastaReader


def _build_fasta(path: Path, n: int) -> None:
    lines = []
    for i in range(n):
        lines.append(f">read_{i}")
        lines.append("ACGTACGT")
    path.write_text("\n".join(lines) + "\n")


def test_fasta_writer_run_progress(tmp_path: Path) -> None:
    n = 5000
    src = tmp_path / "in.fa"
    out = tmp_path / "out.fa"
    _build_fasta(src, n)
    run = FastaReader(src).read_unaligned()

    events: list[tuple[int, int]] = []
    FastaWriter.write_run(run, out, progress=lambda d, t: events.append((d, t)))
    assert len(events) >= n // PROGRESS_INTERVAL_READS, events
    assert events[-1] == (n, n)


def test_fasta_writer_reference_progress(tmp_path: Path) -> None:
    n = 1500  # > one interval to trigger mid-stream fire
    out = tmp_path / "ref.fa"
    ref = ReferenceImport(
        uri="synth",
        chromosomes=[f"chr_{i}" for i in range(n)],
        sequences=[b"ACGT" * 8 for _ in range(n)],
    )

    events: list[tuple[int, int]] = []
    FastaWriter.write_reference(
        ref, out, progress=lambda d, t: events.append((d, t)),
    )
    assert events[-1] == (n, n)
    assert len(events) >= n // PROGRESS_INTERVAL_READS
