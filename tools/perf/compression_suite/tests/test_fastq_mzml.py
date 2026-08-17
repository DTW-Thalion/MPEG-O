# tools/perf/compression_suite/tests/test_fastq_mzml.py
import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formats, verify  # noqa: E402
from formats import fastq, mzml  # noqa: E402,F401

REPO = Path(__file__).resolve().parents[4]
MZML = REPO / "java/src/test/resources/tiny.pwiz.1.1.mzML"


def test_fastq_gz_round_trip(tmp_path):
    p = tmp_path / "in.fastq"
    p.write_text("@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nGGCCAATT\n+\n!!!!####\n")
    fmt = formats.REGISTRY["fastq_gz"]
    enc = fmt.encode(p, tmp_path, None)
    assert enc.suffix == ".gz"
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.fastq_md5(dec) == verify.fastq_md5(p)


def test_mzml_gz_lossless(tmp_path):
    fmt = formats.REGISTRY["mzml_gz"]
    enc = fmt.encode(MZML, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.mzml_arrays_md5(dec) == verify.mzml_arrays_md5(MZML)
    assert fmt.lossy is False


def test_mzml_numpress_is_marked_lossy_and_bounded(tmp_path):
    fmt = formats.REGISTRY["mzml_numpress_gz"]
    assert fmt.lossy is True
    enc = fmt.encode(MZML, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.mzml_max_rel_error(MZML, dec) < 1e-3
