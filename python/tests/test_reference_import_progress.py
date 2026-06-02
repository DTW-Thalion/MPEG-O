"""ProgressSink coverage for ReferenceImport.write_to_dataset.

Mirrors Java ReferenceImport.writeToDataset(..., ProgressSink): emits
(0, N) before the embed loop then (i+1, N) after each contig, ending at
(N, N). N = number of chromosomes. Progress is a runtime callback only.
"""
from __future__ import annotations

from pathlib import Path

from ttio.genomic.reference_import import ReferenceImport
from ttio.spectral_dataset import SpectralDataset


def _embed(tio_path: Path, ri: ReferenceImport, progress=None) -> None:
    SpectralDataset.write_minimal(
        tio_path, title="", isa_investigation_id="", runs={},
    )
    with SpectralDataset.open(tio_path, writable=True) as ds:
        ri.write_to_dataset(ds, progress=progress)


def _ref(n: int) -> ReferenceImport:
    names = [f"chr{i}" for i in range(n)]
    seqs = [b"ACGTACGTACGT" for _ in range(n)]
    return ReferenceImport(uri="prog-v1", chromosomes=names, sequences=seqs)


def test_progress_emits_zero_then_per_contig(tmp_path: Path) -> None:
    n = 3
    events: list[tuple[int, int]] = []
    _embed(tmp_path / "p.tio", _ref(n), progress=lambda d, t: events.append((d, t)))
    # (0,3),(1,3),(2,3),(3,3) — N+1 callbacks, total always N.
    assert events == [(0, n), (1, n), (2, n), (3, n)]


def test_progress_protocol_object_sink(tmp_path: Path) -> None:
    n = 2

    class Collector:
        def __init__(self) -> None:
            self.events: list[tuple[int, int]] = []

        def on_progress(self, done: int, total: int) -> None:
            self.events.append((done, total))

    sink = Collector()
    _embed(tmp_path / "q.tio", _ref(n), progress=sink)
    assert sink.events == [(0, n), (1, n), (2, n)]


def test_progress_none_safe(tmp_path: Path) -> None:
    # No progress arg must still embed cleanly.
    _embed(tmp_path / "r.tio", _ref(2), progress=None)
    with SpectralDataset.open(tmp_path / "r.tio") as ds:
        assert list(ds.references["prog-v1"].chromosomes) == ["chr0", "chr1"]
