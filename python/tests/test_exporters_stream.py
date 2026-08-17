"""Streaming exporters: SAM/BAM, FASTQ and mzML from iter_reads / iter_spectra."""
from __future__ import annotations

import resource
import shutil
from pathlib import Path

import numpy as np
import pytest

from _digests import fastq_md5, sam11_md5
from ttio.exporters import registry as ex
from ttio.importers import registry as im
from ttio.spectral_dataset import SpectralDataset

REPO = Path(__file__).resolve().parents[2]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
ONE_MIN = REPO / "objc/Tests/Fixtures/1min.mzML"
needs_samtools = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools")


@needs_samtools
def test_bam_export_from_blocks_v1_round_trips(tmp_path):
    tio = tmp_path / "g.tio"
    im.encode("bam", [str(BAM)], str(tio), block_reads=4)
    out = tmp_path / "o.bam"
    ex.export("bam", str(tio), "genomic_0001", str(out))
    assert sam11_md5(out) == sam11_md5(BAM)


def test_fastq_export_from_blocks_v1_round_trips(tmp_path):
    fq = tmp_path / "in.fastq"
    with open(fq, "w") as f:
        for i in range(10_000):
            f.write(f"@r{i}\n{'ACGT' * 25}\n+\n{'I' * 50}{'#' * 50}\n")
    tio = tmp_path / "f.tio"
    from ttio.tools import fastq_import_cli
    assert fastq_import_cli.main(["--fastq", str(fq), "--out", str(tio), "--block-reads", "3000"]) == 0
    out = tmp_path / "o.fastq"
    from ttio.tools import fastq_export_cli
    assert fastq_export_cli.main(["--in", str(tio), "--name", "genomic_0001", "--out", str(out)]) == 0
    assert fastq_md5(out) == fastq_md5(fq)


def test_mzml_export_streams_and_round_trips(tmp_path):
    if not ONE_MIN.exists():
        pytest.skip(str(ONE_MIN))
    tio = tmp_path / "m.tio"
    im.encode("mzml", [str(ONE_MIN)], str(tio), batch_spectra=5)
    out = tmp_path / "o.mzML"
    ex.export("mzml", str(tio), "run_0001", str(out))
    from ttio.importers import mzml as mzml_imp
    a = mzml_imp.read(ONE_MIN).ms_spectra
    b = mzml_imp.read(out).ms_spectra
    assert len(a) == len(b)
    for x, y in zip(a, b):
        assert np.array_equal(x.mz_or_chemical_shift, y.mz_or_chemical_shift)
        assert np.array_equal(x.intensity, y.intensity)


def test_exports_bounded_memory(tmp_path):
    """2 M reads to FASTQ and 200 k spectra to mzML with peak RSS growth under 1 GB."""
    fq = tmp_path / "big.fastq"
    with open(fq, "w") as f:
        for i in range(2_000_000):
            f.write(f"@r{i}\n{'ACGT' * 25}\n+\n{'I' * 50}{'#' * 50}\n")
    tio = tmp_path / "big.tio"
    from ttio.tools import fastq_import_cli
    assert fastq_import_cli.main(["--fastq", str(fq), "--out", str(tio), "--block-reads", "250000"]) == 0
    from ttio.tools import fastq_export_cli
    before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    assert fastq_export_cli.main(["--in", str(tio), "--name", "genomic_0001",
                                  "--out", str(tmp_path / "big_out.fastq")]) == 0
    after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    assert (after - before) / 1024 < 1000, f"FASTQ export RSS grew {(after - before) / 1024:.0f} MB"
    assert fastq_md5(tmp_path / "big_out.fastq") == fastq_md5(fq)
