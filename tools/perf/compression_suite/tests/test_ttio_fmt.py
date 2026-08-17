# tools/perf/compression_suite/tests/test_ttio_fmt.py
import shutil, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formats, verify  # noqa: E402
from formats import ttio_fmt  # noqa: E402,F401

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
MZML = REPO / "java/src/test/resources/tiny.pwiz.1.1.mzML"


@pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools missing")
def test_ttio_bam_round_trip(tmp_path):
    fmt = formats.REGISTRY["ttio"]
    enc = fmt.encode(BAM, tmp_path, None)
    assert enc.suffix == ".tio" and enc.stat().st_size > 0
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.sam11_md5(dec) == verify.sam11_md5(BAM)
    assert "ttio" in fmt.version()


def test_ttio_mzml_round_trip(tmp_path):
    fmt = formats.REGISTRY["ttio_mzml"]
    enc = fmt.encode(MZML, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.mzml_arrays_md5(dec) == verify.mzml_arrays_md5(MZML)


def test_ttio_fastq_round_trip(tmp_path):
    p = tmp_path / "in.fastq"
    p.write_text("@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nGGCCAATT\n+\n!!!!####\n")
    fmt = formats.REGISTRY["ttio_fastq"]
    enc = fmt.encode(p, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.fastq_md5(dec) == verify.fastq_md5(p)
