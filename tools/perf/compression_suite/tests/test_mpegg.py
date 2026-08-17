# tools/perf/compression_suite/tests/test_mpegg.py
import shutil, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formats, verify  # noqa: E402
from formats import mpegg  # noqa: E402,F401

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
REF_SRC = REPO / "python/tests/fixtures/genomic/blocks_v1_golden_ref.fa"


@pytest.fixture
def REF(tmp_path):
    """genie writes <stem>.fai and <stem>.sha256 beside the reference it
    is given, so tests use a scratch copy of the repo fixture."""
    import shutil
    dst = tmp_path / "ref" / REF_SRC.name
    dst.parent.mkdir()
    shutil.copyfile(REF_SRC, dst)
    return dst
pytestmark = pytest.mark.skipif(shutil.which("podman") is None or shutil.which("samtools") is None,
                                reason="podman/samtools missing")


def test_mpegg_aligned_round_trip(tmp_path, REF):
    """genie transcodes SAM to MPEG-G records and back. On the m87
    fixture it drops unmapped records that have no adjacent mate and
    does not restore FLAG 0x20 or TLEN, so the 11-column digest is not
    equal; the suite records that as verify FAIL with this summary."""
    fmt = formats.REGISTRY["mpegg"]
    enc = fmt.encode(BAM, tmp_path, REF)
    assert enc.suffix == ".mgb" and enc.stat().st_size > 0
    dec = fmt.decode(enc, tmp_path, REF)
    assert dec.exists()
    n_dec = len(verify._sam11_lines(dec))
    assert n_dec >= 8
    if verify.sam11_md5(dec) != verify.sam11_md5(BAM):
        summary = verify.sam11_diff_summary(BAM, dec)
        assert "TLEN" in summary or "FLAG" in summary or "missing" in summary
    assert "genie" in fmt.version().lower()


def test_mpegg_unaligned_round_trip(tmp_path, REF):
    p = tmp_path / "in.fastq"
    p.write_text("@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nGGCCAATT\n+\n!!!!####\n")
    fmt = formats.REGISTRY["mpegg_unaligned"]
    enc = fmt.encode(p, tmp_path, None)
    dec = fmt.decode(enc, tmp_path, None)
    assert verify.fastq_md5(dec) == verify.fastq_md5(p)
