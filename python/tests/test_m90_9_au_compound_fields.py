"""M90.9: AU compound-field round-trip on the wire.

Closes the M89.2 deferred scope: cigar, read_name, mate_chromosome,
mate_position, template_length all round-trip through .tis transport
back to the same per-AU values, instead of defaulting to "" / -1 / 0.

Wire format:
- cigar, read_name, mate_chromosome ride as additional UINT8
  channels alongside sequences + qualities. Each channel's data
  for a given AU = the per-read string's UTF-8 bytes for THAT AU.
- mate_position (i64) + template_length (i32) extend the M89.1
  genomic suffix at the END (after flags). Decoder is backward-
  compatible: AUs whose payload ends right after flags default
  these to -1 / 0 (preserving M89.1 behaviour).
"""
from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.transport.codec import file_to_transport, transport_to_file
from ttio.transport.packets import AccessUnit, ChannelData
from ttio.written_genomic_run import WrittenGenomicRun


def _make_genomic_dataset(path: Path) -> Path:
    n = 4
    L = 8
    sequences = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.array([0x0003, 0x0083, 0x0003, 0x0083], dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        # M90.9: compound fields with distinct per-read values so a
        # mixup is detectable.
        cigars=["8M", "4M2I2M", "5M3D", "2S6M"],
        read_names=["read_aaaa", "read_bbbb", "read_cccc", "read_dddd"],
        mate_chromosomes=["chr1", "chr1", "=", ""],  # = means same as primary
        mate_positions=np.array([350, 200, 0, -1], dtype=np.int64),
        template_lengths=np.array([250, 0, -300, 0], dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
        # v1.7 Task #12: opt out of inline_v2 so the M90.9 transport
        # round-trip test can verify the v1 compound layout with "=" and ""
        # preserved verbatim (the v2 codec normalises these to actual chrom
        # names and "*" respectively).
        opt_disable_inline_mate_info_v2=True,
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.9 compound-field fixture",
        isa_investigation_id="ISA-M90-9",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestSuffixExtensionWireFormat:

    def test_genomic_au_with_mate_pos_and_template_length(self):
        au = AccessUnit(
            spectrum_class=5,
            acquisition_mode=7, ms_level=0, polarity=2,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[],
            chromosome="chr1", position=100, mapping_quality=60,
            flags=0x0003, mate_position=350, template_length=250,
        )
        decoded = AccessUnit.from_bytes(au.to_bytes())
        assert decoded.chromosome == "chr1"
        assert decoded.position == 100
        assert decoded.mate_position == 350
        assert decoded.template_length == 250

    def test_backward_compat_old_suffix_decodes_with_defaults(self):
        # Manually craft an AU with the M89.1 suffix only (no mate
        # extension); decoder MUST default mate_position=-1 + tlen=0.
        import struct
        from ttio.transport.packets import (
            _AU_PREFIX_STRUCT, _AU_GENOMIC_FIXED_STRUCT, pack_string,
        )
        prefix = _AU_PREFIX_STRUCT.pack(
            5, 7, 0, 2, 0.0, 0.0, 0, 0.0, 0.0, 0,
        )
        suffix = pack_string("chr1", width=2) + _AU_GENOMIC_FIXED_STRUCT.pack(
            100, 60, 0x0003,
        )
        decoded = AccessUnit.from_bytes(prefix + suffix)
        assert decoded.chromosome == "chr1"
        assert decoded.mate_position == -1
        assert decoded.template_length == 0


class TestRoundTrip:

    def test_round_trip_preserves_compound_fields(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        rt = transport_to_file(buffer, tmp_path / "rt.tio")
        try:
            assert "genomic_0001" in rt.genomic_runs
            gr = rt.genomic_runs["genomic_0001"]
            # All compound fields must round-trip per-AU.
            cigars = [gr[i].cigar for i in range(len(gr))]
            assert cigars == ["8M", "4M2I2M", "5M3D", "2S6M"]
            read_names = [gr[i].read_name for i in range(len(gr))]
            assert read_names == ["read_aaaa", "read_bbbb", "read_cccc", "read_dddd"]
            mate_chroms = [gr[i].mate_chromosome for i in range(len(gr))]
            assert mate_chroms == ["chr1", "chr1", "=", ""]
            mate_positions = [gr[i].mate_position for i in range(len(gr))]
            assert mate_positions == [350, 200, 0, -1]
            template_lengths = [gr[i].template_length for i in range(len(gr))]
            assert template_lengths == [250, 0, -300, 0]
        finally:
            rt.close()

    def test_sequences_and_qualities_still_round_trip(self, tmp_path):
        # Regression check — M90.9 must not break the M89.2 baseline.
        src = _make_genomic_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        rt = transport_to_file(buffer, tmp_path / "rt.tio")
        try:
            gr = rt.genomic_runs["genomic_0001"]
            for i in range(len(gr)):
                assert gr[i].sequence == "ACGTACGT"
                assert gr[i].qualities == bytes([30] * 8)
        finally:
            rt.close()
