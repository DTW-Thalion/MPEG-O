"""M90.14: seeded-RNG random quality scores.

Closes gap #8 from the post-M90 analysis. The M90.3 randomise_qualities
policy replaces every Phred byte with a single constant — adequate
for hiding per-base error patterns but too uniform for some
epidemiology pipelines that expect realistic Phred distributions.

M90.14 adds an optional ``randomise_qualities_seed`` field. When set,
qualities are replaced with deterministic random Phred scores drawn
from a numpy RNG seeded with that value. Reproducible across runs.
The constant-replacement behaviour is the default (seed=None).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.anonymization import AnonymizationPolicy, anonymize
from ttio.written_genomic_run import WrittenGenomicRun


def _make_genomic_dataset(path: Path) -> Path:
    n = 4
    L = 8
    sequences = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    # Distinct per-read qualities so an unintended carry-through
    # would be detectable.
    quals = bytes()
    for i in range(n):
        quals += bytes([10 + i] * L)
    qualities = np.frombuffer(quals, dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"r{i}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1"] * n,
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.14 seeded fixture",
        isa_investigation_id="ISA-M90-14",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestSeededRandom:

    def test_seed_produces_reproducible_qualities(self, tmp_path):
        """Same seed → same output bytes across two anonymize() calls."""
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out_a = tmp_path / "a.tio"
        out_b = tmp_path / "b.tio"
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(
                randomise_qualities=True,
                randomise_qualities_seed=42,
            )
            anonymize(ds, out_a, policy)
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(
                randomise_qualities=True,
                randomise_qualities_seed=42,
            )
            anonymize(ds, out_b, policy)
        with SpectralDataset.open(out_a) as ds_a, \
             SpectralDataset.open(out_b) as ds_b:
            ga = ds_a.genomic_runs["genomic_0001"]
            gb = ds_b.genomic_runs["genomic_0001"]
            for i in range(len(ga)):
                assert ga[i].qualities == gb[i].qualities, (
                    f"read {i}: same seed must produce same qualities"
                )

    def test_different_seeds_produce_different_qualities(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out_a = tmp_path / "a.tio"
        out_b = tmp_path / "b.tio"
        with SpectralDataset.open(src) as ds:
            anonymize(ds, out_a, AnonymizationPolicy(
                randomise_qualities=True,
                randomise_qualities_seed=42,
            ))
        with SpectralDataset.open(src) as ds:
            anonymize(ds, out_b, AnonymizationPolicy(
                randomise_qualities=True,
                randomise_qualities_seed=99,
            ))
        with SpectralDataset.open(out_a) as ds_a, \
             SpectralDataset.open(out_b) as ds_b:
            ga = ds_a.genomic_runs["genomic_0001"]
            gb = ds_b.genomic_runs["genomic_0001"]
            differs = False
            for i in range(len(ga)):
                if ga[i].qualities != gb[i].qualities:
                    differs = True
                    break
            assert differs, "different seeds must produce different qualities"

    def test_seed_qualities_are_in_phred_range(self, tmp_path):
        """Generated Phred values must fit in uint8 (0-93 by SAM spec,
        but anything ≤93 is valid for Illumina-style)."""
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "out.tio"
        with SpectralDataset.open(src) as ds:
            anonymize(ds, out, AnonymizationPolicy(
                randomise_qualities=True,
                randomise_qualities_seed=42,
            ))
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            for i in range(len(gr)):
                for byte in gr[i].qualities:
                    assert 0 <= byte <= 93, (
                        f"read {i} byte {byte}: Phred must be 0-93"
                    )

    def test_seed_overrides_constant(self, tmp_path):
        """When both seed and constant are set, seed takes precedence
        (deterministic random, not the constant)."""
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "out.tio"
        with SpectralDataset.open(src) as ds:
            anonymize(ds, out, AnonymizationPolicy(
                randomise_qualities=True,
                randomise_qualities_constant=30,  # would be uniform
                randomise_qualities_seed=7,        # but seed wins
            ))
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            r0 = gr[0]
            # Confirm not all 30s (would mean seed was ignored).
            assert r0.qualities != bytes([30] * 8), (
                "seed must override the constant"
            )


class TestConstantBehaviorPreserved:
    """Default (seed=None) behaviour must still be the M90.3
    constant-replacement path."""

    def test_no_seed_uses_constant(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "out.tio"
        with SpectralDataset.open(src) as ds:
            anonymize(ds, out, AnonymizationPolicy(
                randomise_qualities=True,
                randomise_qualities_constant=30,
            ))
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            for i in range(len(gr)):
                assert gr[i].qualities == bytes([30] * 8), (
                    f"read {i}: no seed → all bytes equal constant 30"
                )
