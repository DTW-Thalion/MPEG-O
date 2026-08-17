"""FASTA / FASTQ I/O performance benchmark suite.

Mirrors the per-provider stress style of
``test_provider_benchmark.py`` but for the FASTA / FASTQ
import + export + ``.tio`` round-trip pipeline. Records every
timing + size to ``tests/stress/benchmark_results.json`` so
release-to-release regressions surface.

Scenarios (per fixture size):

1. ``fastq_export``   — write a fresh ``WrittenGenomicRun`` to FASTQ.
2. ``fastq_import``   — parse the produced FASTQ back.
3. ``fastq_tio_round_trip`` — full FASTQ → ``.tio`` (with
   NAME_TOKENIZED_V2 + the v2 qualities codec) → FASTQ.
4. ``fasta_export``   — write a reference / read run to FASTA + ``.fai``.
5. ``fasta_import``   — parse the produced FASTA.

Fixture sizes are deliberately modest so the suite finishes in the
nightly stress window (single-threaded, no warmup):

- ``small``: 1,000 reads × 100 bp
- ``medium``: 10,000 reads × 100 bp

Assertions are loose (the suite is a regression-tracker, not a
benchmark gate). Hard ceilings catch only outright pathologies.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import pytest

# These tests exercise the v1.8 whole-channel layout (per-AU and region
# encryption slice plaintext channels, per-dataset signatures and the
# refdiff_v2 group shape); every genomic write in this module uses it.
pytestmark = pytest.mark.usefixtures("legacy_genomic_layout")

from ttio import SpectralDataset, WrittenGenomicRun
from ttio.exporters.fasta import FastaWriter
from ttio.exporters.fastq import FastqWriter
from ttio.importers.fasta import FastaReader
from ttio.importers.fastq import FastqReader

_RESULTS_PATH = Path(__file__).resolve().parent / "benchmark_results.json"


def _load_results() -> dict:
    if _RESULTS_PATH.is_file():
        return json.loads(_RESULTS_PATH.read_text())
    return {}


def _record(scenario: str, **payload) -> None:
    """Append a benchmark entry keyed by ('fasta_fastq', scenario).

    Uses the same on-disk format as
    :mod:`test_provider_benchmark` so a single results file
    aggregates all stress timings.
    """
    results = _load_results()
    by_section = results.setdefault("fasta_fastq", {})
    by_section[scenario] = {"timestamp_unix": int(time.time()), **payload}
    _RESULTS_PATH.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")


def _build_run(n: int, read_length: int, rng: np.random.Generator) -> WrittenGenomicRun:
    bases = b"ACGT"
    seq = np.frombuffer(
        (bases * ((n * read_length) // 4 + 1))[: n * read_length],
        dtype=np.uint8,
    )
    qual = np.full(n * read_length, 30, dtype=np.uint8)
    return WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="bench",
        positions=np.arange(n, dtype=np.int64) * 100,
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 3, dtype=np.uint32),
        sequences=seq,
        qualities=qual,
        offsets=np.arange(n, dtype=np.uint64) * read_length,
        lengths=np.full(n, read_length, dtype=np.uint32),
        cigars=[f"{read_length}M"] * n,
        read_names=[f"read_{i:08d}.lane.{i % 4 + 1}" for i in range(n)],
        mate_chromosomes=["="] * n,
        mate_positions=np.arange(n, dtype=np.int64) * 200,
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1"] * n,
    )


def _native_lib_available() -> bool:
    rans = os.environ.get("TTIO_RANS_LIB_PATH", "")
    if rans and os.path.isfile(rans):
        return True
    repo_root = Path(__file__).resolve().parents[3]
    candidate = repo_root / "native" / "_build" / "libttio_rans.so"
    if candidate.is_file():
        os.environ.setdefault("TTIO_RANS_LIB_PATH", str(candidate))
        return True
    return False


pytestmark = [
    pytest.mark.stress,
    pytest.mark.skipif(
        not _native_lib_available(),
        reason="FASTA/FASTQ → .tio round-trip needs libttio_rans for the v2 codecs",
    ),
]


_FIXTURE_SIZES = [
    ("small", 1_000, 100),
    ("medium", 10_000, 100),
]
# Long-tail scaling cells. Opt-in via TTIO_INCLUDE_LONG_TAIL=1 since
# they take ~minutes each and aren't appropriate for the per-PR
# nightly window. The 1M cell exercises the same v2 codec stack at
# production-Illumina scale (one HiSeq lane ≈ 200-400M reads).
if os.environ.get("TTIO_INCLUDE_LONG_TAIL") == "1":
    _FIXTURE_SIZES.extend([
        ("large", 100_000, 100),
        ("xlarge", 1_000_000, 100),
    ])


@pytest.mark.parametrize("size_name,n_reads,read_length", _FIXTURE_SIZES)
class TestFastaFastqBench:
    """Each cell records timing + on-disk size for one fixture size."""

    def test_fastq_export(
        self, size_name: str, n_reads: int, read_length: int,
        tmp_path: Path,
    ) -> None:
        rng = np.random.default_rng(7)
        run = _build_run(n_reads, read_length, rng)
        out = tmp_path / f"{size_name}.fastq"
        t0 = time.perf_counter()
        FastqWriter.write(run, out)
        elapsed = time.perf_counter() - t0
        size_bytes = out.stat().st_size
        _record(
            f"fastq_export_{size_name}",
            n_reads=n_reads, read_length=read_length,
            seconds=round(elapsed, 4), bytes=size_bytes,
        )
        # Sanity ceiling: ~1 MB FASTQ should write in well under 5 s.
        assert elapsed < 30.0

    def test_fastq_import(
        self, size_name: str, n_reads: int, read_length: int,
        tmp_path: Path,
    ) -> None:
        rng = np.random.default_rng(7)
        run = _build_run(n_reads, read_length, rng)
        path = tmp_path / f"{size_name}.fastq"
        FastqWriter.write(run, path)
        t0 = time.perf_counter()
        result = FastqReader(path).read()
        elapsed = time.perf_counter() - t0
        _record(
            f"fastq_import_{size_name}",
            n_reads=n_reads, read_length=read_length,
            seconds=round(elapsed, 4),
        )
        assert len(result.read_names) == n_reads
        assert elapsed < 30.0

    def test_fastq_tio_round_trip(
        self, size_name: str, n_reads: int, read_length: int,
        tmp_path: Path,
    ) -> None:
        """FASTQ → ``.tio`` → FASTQ. The middle hop exercises
        NAME_TOKENIZED_V2 + the v2 qualities codec."""
        rng = np.random.default_rng(7)
        run = _build_run(n_reads, read_length, rng)
        fq_in = tmp_path / f"{size_name}_in.fastq"
        FastqWriter.write(run, fq_in)
        size_in = fq_in.stat().st_size

        tio = tmp_path / f"{size_name}.tio"
        t0 = time.perf_counter()
        SpectralDataset.write_minimal(
            str(tio), title="bench", isa_investigation_id="ISA-FQ",
            runs={}, genomic_runs={"genomic_0001": run},
        )
        write_elapsed = time.perf_counter() - t0
        size_tio = tio.stat().st_size

        fq_out = tmp_path / f"{size_name}_out.fastq"
        t0 = time.perf_counter()
        with SpectralDataset.open(tio) as ds:
            gr = ds.genomic_runs["genomic_0001"]
            FastqWriter.write(gr, fq_out)
        export_elapsed = time.perf_counter() - t0
        size_out = fq_out.stat().st_size

        ratio_tio_vs_fastq = size_tio / size_in if size_in > 0 else 0.0
        _record(
            f"fastq_tio_round_trip_{size_name}",
            n_reads=n_reads, read_length=read_length,
            tio_write_seconds=round(write_elapsed, 4),
            fastq_export_seconds=round(export_elapsed, 4),
            fastq_in_bytes=size_in,
            tio_bytes=size_tio,
            fastq_out_bytes=size_out,
            tio_compression_ratio=round(ratio_tio_vs_fastq, 3),
        )
        # FASTQ in/out should be near-identical (FASTQ is the lossy
        # presentation; the .tio is denser, FASTQ re-export is byte-
        # equivalent within Phred sentinel handling).
        assert size_out > 0
        assert write_elapsed < 60.0

    def test_fasta_export(
        self, size_name: str, n_reads: int, read_length: int,
        tmp_path: Path,
    ) -> None:
        rng = np.random.default_rng(7)
        run = _build_run(n_reads, read_length, rng)
        out = tmp_path / f"{size_name}.fasta"
        t0 = time.perf_counter()
        FastaWriter.write_run(run, out, line_width=60, write_fai=True)
        elapsed = time.perf_counter() - t0
        size_bytes = out.stat().st_size
        fai = out.with_suffix(out.suffix + ".fai")
        fai_size = fai.stat().st_size if fai.is_file() else 0
        _record(
            f"fasta_export_{size_name}",
            n_reads=n_reads, read_length=read_length,
            seconds=round(elapsed, 4),
            bytes=size_bytes, fai_bytes=fai_size,
        )
        assert elapsed < 30.0

    def test_fasta_import(
        self, size_name: str, n_reads: int, read_length: int,
        tmp_path: Path,
    ) -> None:
        rng = np.random.default_rng(7)
        run = _build_run(n_reads, read_length, rng)
        path = tmp_path / f"{size_name}.fasta"
        FastaWriter.write_run(run, path, line_width=60)
        t0 = time.perf_counter()
        result = FastaReader(path).read_unaligned()
        elapsed = time.perf_counter() - t0
        _record(
            f"fasta_import_{size_name}",
            n_reads=n_reads, read_length=read_length,
            seconds=round(elapsed, 4),
        )
        assert len(result.read_names) == n_reads
        assert elapsed < 30.0
