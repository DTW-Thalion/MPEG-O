"""M90.13: region masking by SAM overlap (CIGAR-walked end coord).

Closes gap #7 from the post-M90 analysis. M90.3's mask_regions
checked only the read's mapping POSITION — a read whose start was
just before a masked region but whose alignment extended INTO the
region was NOT masked, leaking the masked sequence.

M90.13 walks the CIGAR to compute the reference end coordinate so a
read overlaps a region iff [read_start, read_end] intersects
[region_start, region_end].

CIGAR ops that consume reference bases: M, D, N, =, X.
CIGAR ops that don't: I, S, H, P.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.anonymization import AnonymizationPolicy, anonymize
from ttio.written_genomic_run import WrittenGenomicRun


def _make_overlap_dataset(path: Path) -> Path:
    """6 reads on chr1 with carefully chosen positions + cigars to
    exercise SAM-overlap semantics around the region [100, 200]."""
    n = 6
    L = 8
    sequences = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8)
    # Positions chosen so each read tests a different overlap case.
    positions = np.array(
        [50, 95, 100, 150, 200, 250],
        dtype=np.int64,
    )
    # CIGARs:
    #   read 0: pos=50,  "8M"     -> ref [50, 58)   — entirely before region [100,200]
    #   read 1: pos=95,  "8M"     -> ref [95, 103)  — overlaps region (extends in)
    #   read 2: pos=100, "8M"     -> ref [100, 108) — starts in region (M90.3 also catches)
    #   read 3: pos=150, "4M2I2M" -> ref [150, 156) — entirely in region
    #   read 4: pos=200, "8M"     -> ref [200, 208) — overlaps at boundary
    #   read 5: pos=250, "8M"     -> ref [250, 258) — entirely after region
    cigars = ["8M", "8M", "8M", "4M2I2M", "8M", "8M"]
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
        cigars=cigars,
        read_names=[f"r{i}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1"] * n,
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.13 overlap fixture",
        isa_investigation_id="ISA-M90-13",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestSamOverlapMasking:

    def test_read_starting_before_extending_into_region_is_masked(self, tmp_path):
        """The M90.3 BUG: read at pos=95 with cigar 8M ends at ref
        position 102 (overlaps region [100, 200]). Pre-M90.13 this
        was not masked — only pos=95 was checked, which is < 100."""
        src = _make_overlap_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            policy = AnonymizationPolicy(
                mask_regions=[("chr1", 100, 200)],
            )
            result = anonymize(ds, out, policy)
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            # read 0 (pos=50, end=58): entirely before — not masked
            assert gr[0].sequence == "ACGTACGT"
            # read 1 (pos=95, end=103): overlaps [100, 200] — MASKED
            assert gr[1].sequence == "\x00" * 8, (
                "M90.13: read at pos=95 + CIGAR 8M extends to "
                "reference position 103, overlapping the region"
            )
            # read 2 (pos=100, end=108): in region — masked
            assert gr[2].sequence == "\x00" * 8
            # read 3 (pos=150, end=156): entirely in region — masked
            assert gr[3].sequence == "\x00" * 8
            # read 4 (pos=200, end=208): boundary inclusive — masked
            assert gr[4].sequence == "\x00" * 8
            # read 5 (pos=250, end=258): entirely after — not masked
            assert gr[5].sequence == "ACGTACGT"
        # 4 reads masked: 1, 2, 3, 4.
        assert result.reads_in_masked_region == 4

    def test_cigar_with_insertion_does_not_consume_ref(self, tmp_path):
        """Verify that I (insertion) ops in CIGAR are correctly
        treated as not consuming reference bases. read 3's CIGAR
        is '4M2I2M' which consumes 6 ref bases (4 M + 2 M; the 2 I
        consume query bases but not reference). Without this rule,
        the end coord would be wrongly inflated to 158."""
        src = _make_overlap_dataset(tmp_path / "src.tio")
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(src) as ds:
            # Region that ends EXACTLY at where read 3 should end.
            # read 3: pos=150, CIGAR=4M2I2M -> end=156.
            # Region [157, 1000] — read 3 should NOT be masked
            # (its end at 156 is just before).
            policy = AnonymizationPolicy(
                mask_regions=[("chr1", 157, 1000)],
            )
            anonymize(ds, out, policy)
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            # read 3 must NOT be masked — the I op did not consume ref.
            assert gr[3].sequence == "ACGTACGT", (
                "M90.13 bug: CIGAR 4M2I2M end-coord must be 156, not 158"
            )

    def test_cigar_with_deletion_consumes_ref(self, tmp_path):
        """D (deletion) op consumes reference bases. A read with
        position=180 and CIGAR=2M3D5M consumes 10 ref bases, ending
        at 190."""
        path = tmp_path / "del.tio"
        n = 1
        L = 7  # 2M + 5M = 7 query bases
        run = WrittenGenomicRun(
            acquisition_mode=7,
            reference_uri="GRCh38.p14",
            platform="ILLUMINA",
            sample_name="NA12878",
            positions=np.array([180], dtype=np.int64),
            mapping_qualities=np.array([60], dtype=np.uint8),
            flags=np.array([0x0003], dtype=np.uint32),
            sequences=np.frombuffer(b"ACGTACG", dtype=np.uint8),
            qualities=np.frombuffer(bytes([30] * L), dtype=np.uint8),
            offsets=np.array([0], dtype=np.uint64),
            lengths=np.array([L], dtype=np.uint32),
            cigars=["2M3D5M"],
            read_names=["r0"],
            mate_chromosomes=[""],
            mate_positions=np.array([-1], dtype=np.int64),
            template_lengths=np.array([0], dtype=np.int32),
            chromosomes=["chr1"],
        )
        SpectralDataset.write_minimal(
            path, title="x", isa_investigation_id="x",
            runs={}, genomic_runs={"genomic_0001": run},
        )
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(path) as ds:
            # Region [185, 200] — read end=190 overlaps.
            policy = AnonymizationPolicy(
                mask_regions=[("chr1", 185, 200)],
            )
            result = anonymize(ds, out, policy)
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            assert gr[0].sequence == "\x00" * L, (
                "M90.13: read end (after 3D consuming 3 ref bases) "
                "must overlap the region"
            )
        assert result.reads_in_masked_region == 1


class TestPosOnlyBackwardCompat:
    """When CIGAR is empty/missing/non-parseable, fall back to
    M90.3's position-only check (preserves M90.3 behaviour)."""

    def test_empty_cigar_uses_position_only(self, tmp_path):
        path = tmp_path / "empty.tio"
        n = 1
        L = 8
        run = WrittenGenomicRun(
            acquisition_mode=7,
            reference_uri="GRCh38.p14",
            platform="ILLUMINA",
            sample_name="NA12878",
            positions=np.array([95], dtype=np.int64),
            mapping_qualities=np.array([60], dtype=np.uint8),
            flags=np.array([0x0003], dtype=np.uint32),
            sequences=np.frombuffer(b"ACGTACGT", dtype=np.uint8),
            qualities=np.frombuffer(bytes([30] * L), dtype=np.uint8),
            offsets=np.array([0], dtype=np.uint64),
            lengths=np.array([L], dtype=np.uint32),
            cigars=[""],  # empty CIGAR
            read_names=["r0"],
            mate_chromosomes=[""],
            mate_positions=np.array([-1], dtype=np.int64),
            template_lengths=np.array([0], dtype=np.int32),
            chromosomes=["chr1"],
        )
        SpectralDataset.write_minimal(
            path, title="x", isa_investigation_id="x",
            runs={}, genomic_runs={"genomic_0001": run},
        )
        out = tmp_path / "anon.tio"
        with SpectralDataset.open(path) as ds:
            # Region [100, 200] — pos=95 is < 100. With CIGAR walked
            # we can't know the end; fall back to position-only:
            # 95 < 100, so NOT masked.
            policy = AnonymizationPolicy(
                mask_regions=[("chr1", 100, 200)],
            )
            anonymize(ds, out, policy)
        with SpectralDataset.open(out) as ds_out:
            gr = ds_out.genomic_runs["genomic_0001"]
            assert gr[0].sequence == "ACGTACGT", (
                "empty CIGAR + pos=95 < region_start=100 → not masked"
            )
