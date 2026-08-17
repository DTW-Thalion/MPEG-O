"""The committed blocks_v1 golden fixture (format-spec 10.12): the
cross-language decode contract for the block layout."""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from _digests import genomic_run_sam11_md5, sam11_md5
from ttio import _hdf5_io as io
from ttio.enums import Compression
from ttio.spectral_dataset import SpectralDataset

HERE = Path(__file__).resolve().parent
GOLDEN = HERE / "fixtures/genomic/blocks_v1_golden.tio"
BAM = HERE / "fixtures/genomic/m87_test.bam"
needs_samtools = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools")


def test_golden_layout():
    with SpectralDataset.open(str(GOLDEN)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert g.layout == "blocks_v1"
        assert g.block_count == 4 and len(g) == 10
        assert io.read_string_attr(g.group, "layout") == "blocks_v1"
        rows = g.group.open_group("blocks").open_dataset("index").read_rows()
        assert [int(r["n_reads"]) for r in rows] == [4, 1, 2, 3]
        assert [int(r["read_start"]) for r in rows] == [0, 4, 5, 7]
        # mapped blocks: REF_DIFF_V2 + FQZCOMP; the unmapped block falls
        # back (BASE_PACK sequences, RANS_ORDER0 qualities: it holds a
        # zero-length read)
        assert [int(r["sequences_codec"]) for r in rows] == [14, 14, 14, int(Compression.BASE_PACK)]
        assert [int(r["qualities_codec"]) for r in rows] == [12, 12, 12, int(Compression.RANS_ORDER0)]
        assert [int(r["read_names_codec"]) for r in rows] == [15] * 4
        assert [int(r["cigars_codec"]) for r in rows] == [int(Compression.RANS_ORDER0)] * 4
        assert [int(r["mate_info_codec"]) for r in rows] == [13] * 4
        sc = g.group.open_group("signal_channels")
        assert sc.open_group("sequences").has_child("data")
        assert ds.study_group.has_child("references")


@needs_samtools
def test_golden_content_matches_source_bam():
    with SpectralDataset.open(str(GOLDEN)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert genomic_run_sam11_md5(g) == sam11_md5(BAM)


@needs_samtools
def test_ttio_encode_cli_block_flags(tmp_path):
    out = tmp_path / "cli.tio"
    cli = [sys.executable, "-m", "ttio.tools.workbench_cli"]
    r = subprocess.run(cli + ["encode", "--input", str(BAM), "--format", "bam",
                              "--output", str(out), "--block-reads", "3"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    with SpectralDataset.open(str(out)) as ds:
        g = ds.genomic_runs["genomic_0001"]
        assert g.layout == "blocks_v1" and g.block_count >= 4
    legacy = tmp_path / "legacy.tio"
    r = subprocess.run(cli + ["encode", "--input", str(BAM), "--format", "bam",
                              "--output", str(legacy), "--legacy-whole-channel"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    with SpectralDataset.open(str(legacy)) as ds:
        assert ds.genomic_runs["genomic_0001"].layout == "whole"
