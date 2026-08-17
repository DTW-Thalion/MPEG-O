"""PT2: GenomicRun caches the signal_channels group handle.

Behavioral guard for the P1.4 perf optimization: ``GenomicRun`` must open
``signal_channels`` from ``self.group`` AT MOST ONCE across all per-record
signal accesses (sequences / qualities / cigars / read_names / mate_info),
reusing one cached handle thereafter. Materialised data must be unchanged.

The test:
1. Writes a small genomic ``.tio`` (m82-style fixture).
2. Opens the ``GenomicRun`` and spies on ``run.group.open_group`` to count
   calls made with the ``"signal_channels"`` argument.
3. Materialises several reads across several fields, asserting the data
   round-trips AND that ``open_group("signal_channels")`` is called at most
   once AFTER the spy is installed.

On CURRENT code this FAILS (each helper re-opens the group → count > 1);
after PT2 it PASSES (one cached handle).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

# Whole-channel read mechanics (v1.8 layout).
pytestmark = pytest.mark.usefixtures("legacy_genomic_layout")


def _make_written_run(n_reads: int = 12, read_length: int = 60):
    """Build a synthetic WrittenGenomicRun with cigars/read_names/mate_info."""
    from ttio.written_genomic_run import WrittenGenomicRun

    chromosomes = ["chr1", "chr2", "chrX"]
    rng = np.random.default_rng(7)

    chroms = [chromosomes[i % len(chromosomes)] for i in range(n_reads)]
    positions = np.array(
        [1 + (i // len(chromosomes)) * 100 for i in range(n_reads)],
        dtype=np.int64,
    )
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapqs = np.full(n_reads, 60, dtype=np.uint8)

    seq_concat = bytes(
        rng.choice(list(b"ACGT"), size=n_reads * read_length).tolist()
    )
    qual_concat = bytes([30] * (n_reads * read_length))
    sequences = np.frombuffer(seq_concat, dtype=np.uint8)
    qualities = np.frombuffer(qual_concat, dtype=np.uint8)

    offsets = np.arange(n_reads, dtype=np.uint64) * read_length
    lengths = np.full(n_reads, read_length, dtype=np.uint32)
    cigars = [f"{read_length}M" for _ in range(n_reads)]
    read_names = [f"read_{i:06d}" for i in range(n_reads)]

    return WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=mapqs,
        flags=flags,
        sequences=sequences,
        qualities=qualities,
        offsets=offsets,
        lengths=lengths,
        cigars=cigars,
        read_names=read_names,
        mate_chromosomes=["*" for _ in range(n_reads)],
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=chroms,
    )


def _write_dataset(tmp_path: Path) -> Path:
    from ttio.spectral_dataset import SpectralDataset

    out = tmp_path / "signal_group_cache.tio"
    SpectralDataset.write_minimal(
        out,
        title="pt2-signal-group-cache",
        isa_investigation_id="PT2-001",
        runs={},
        genomic_runs={"genomic_0001": _make_written_run()},
    )
    return out


def test_signal_channels_group_opened_at_most_once(tmp_path: Path):
    from ttio.spectral_dataset import SpectralDataset

    out = _write_dataset(tmp_path)

    ds = SpectralDataset.open(out)
    try:
        run = ds.genomic_runs["genomic_0001"]

        # Install a counting spy on the underlying StorageGroup.open_group,
        # recording ONLY calls that target the signal_channels group. Any
        # eager open performed by GenomicRun.open() already happened before
        # this point, so the count reflects per-record accesses only.
        real_open_group = run.group.open_group
        signal_open_count = {"n": 0}

        def _counting_open_group(name, *args, **kwargs):
            if name == "signal_channels":
                signal_open_count["n"] += 1
            return real_open_group(name, *args, **kwargs)

        run.group.open_group = _counting_open_group  # type: ignore[method-assign]

        # Materialise several reads across several fields. Each AlignedRead
        # touches sequences, qualities, cigars, read_names and mate_info —
        # every one of which (pre-PT2) re-opened signal_channels.
        n = len(run)
        assert n == 12
        records = [run[i] for i in (0, 1, 2, 5, 11)]

        # Behaviour unchanged: data must round-trip / be well-formed.
        for rec in records:
            assert rec.read_name.startswith("read_")
            assert len(rec.sequence) == 60
            assert len(rec.qualities) == 60
            assert rec.cigar == "60M"
            assert rec.chromosome in {"chr1", "chr2", "chrX"}

        # The crux: signal_channels opened AT MOST ONCE across all the
        # above accesses (cached handle reused). Pre-PT2 this is > 1.
        assert signal_open_count["n"] <= 1, (
            "signal_channels group was re-opened "
            f"{signal_open_count['n']} times across per-record accesses; "
            "PT2 requires a single cached handle (<= 1)"
        )
    finally:
        ds.close()
