"""M90.3: genomic anonymisation policies.

Adds three new policies to AnonymizationPolicy:

- strip_read_names: replaces every read_name with an empty string.
- randomise_qualities: replaces per-base Phred scores with a single
  caller-specified constant (default 30). The "randomise" name is
  faithful to the M90 spec language; the actual replacement is
  deterministic per-read so anonymised .tio files stay reproducible.
- mask_regions: a list of (chromosome, start, end) tuples; any read
  whose mapping position falls in any region has its sequence
  bytes zeroed (and qualities zeroed) but its index entry kept,
  preserving read count + read offsets so downstream tooling that
  iterates by index still sees N reads.

The anonymize() entry point is extended to also walk source.genomic_runs
and write modified WrittenGenomicRun copies via write_minimal.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.anonymization import (
    AnonymizationPolicy,
    anonymize,
)
from ttio.written_genomic_run import WrittenGenomicRun


def _make_genomic_dataset(path: Path) -> Path:
    """6 reads across chr1, chr1, chr2, chr3, chr3, chr3."""
    n = 6
    L = 8
    chromosomes = ["chr1", "chr1", "chr2", "chr3", "chr3", "chr3"]
    positions = np.array([100, 200, 50, 1000, 2000, 3000], dtype=np.int64)
    sequences = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    # Distinct quality per read so we can prove randomisation worked.
    quals = bytes()
    for i in range(n):
        quals += bytes([10 + i] * L)
    qualities = np.frombuffer(quals, dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"sensitive_id_{i:04d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=chromosomes,
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.3 anon fixture",
        isa_investigation_id="ISA-M90-3",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestStripReadNames:

    def test_replaces_all_read_names_with_empty_strings(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(strip_read_names=True)
            result = anonymize(ds, out, policy)
        assert "strip_read_names" in result.policies_applied
        assert result.read_names_stripped == 6
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            for i in range(len(gr)):
                assert gr[i].read_name == ""

    def test_other_fields_preserved(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(strip_read_names=True)
            anonymize(ds, out, policy)
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            assert gr.index.chromosomes == [
                "chr1", "chr1", "chr2", "chr3", "chr3", "chr3",
            ]
            np.testing.assert_array_equal(
                gr.index.positions,
                np.array([100, 200, 50, 1000, 2000, 3000], dtype=np.int64),
            )
            # Sequences untouched.
            assert gr[0].sequence == "ACGTACGT"


class TestRandomiseQualities:

    def test_replaces_qualities_with_constant(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(
                randomise_qualities=True,
                randomise_qualities_constant=30,
            )
            result = anonymize(ds, out, policy)
        assert "randomise_qualities" in result.policies_applied
        assert result.qualities_randomised == 6
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            for i in range(len(gr)):
                # Every Phred byte is 30.
                assert gr[i].qualities == bytes([30] * 8)

    def test_default_constant_is_30(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            # Don't pass the constant — default should be 30.
            policy = AnonymizationPolicy(randomise_qualities=True)
            anonymize(ds, out, policy)
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            assert gr[0].qualities == bytes([30] * 8)


class TestMaskRegions:

    def test_zeros_sequences_in_region(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            # Mask all of chr1 (positions 0..1000).
            policy = AnonymizationPolicy(
                mask_regions=[("chr1", 0, 1000)],
            )
            result = anonymize(ds, out, policy)
        assert "mask_regions" in result.policies_applied
        # 2 reads on chr1 (positions 100, 200) match.
        assert result.reads_in_masked_region == 2
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            # First two reads (chr1) zeroed; rest preserved.
            assert gr[0].sequence == "\x00" * 8
            assert gr[1].sequence == "\x00" * 8
            assert gr[2].sequence == "ACGTACGT"  # chr2, unmasked
            assert gr[3].sequence == "ACGTACGT"  # chr3, unmasked

    def test_preserves_read_count_and_index(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(
                mask_regions=[("chr1", 0, 1000)],
            )
            anonymize(ds, out, policy)
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            # Same read count; same chromosomes/positions array.
            assert len(gr) == 6
            assert gr.index.chromosomes == [
                "chr1", "chr1", "chr2", "chr3", "chr3", "chr3",
            ]

    def test_multiple_regions(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(
                mask_regions=[
                    ("chr1", 0, 1000),
                    ("chr3", 1500, 2500),
                ],
            )
            result = anonymize(ds, out, policy)
        # 2 chr1 reads + 1 chr3 read at position 2000 = 3.
        assert result.reads_in_masked_region == 3


class TestCombinedPolicies:

    def test_strip_names_and_mask_chr1(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(
                strip_read_names=True,
                mask_regions=[("chr1", 0, 1000)],
            )
            result = anonymize(ds, out, policy)
        assert result.read_names_stripped == 6
        assert result.reads_in_masked_region == 2
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            assert gr[0].read_name == ""
            assert gr[0].sequence == "\x00" * 8
            assert gr[2].sequence == "ACGTACGT"  # chr2

    def test_no_genomic_policy_leaves_genomic_run_intact(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            # Empty policy — should still copy genomic_runs verbatim.
            policy = AnonymizationPolicy()
            anonymize(ds, out, policy)
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            assert len(gr) == 6
            assert gr[0].read_name == "sensitive_id_0000"
            assert gr[0].sequence == "ACGTACGT"
