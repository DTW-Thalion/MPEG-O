# tools/perf/compression_suite/tests/test_bam_cram.py
import shutil, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formats, verify  # noqa: E402
from formats import bam_cram  # noqa: E402,F401

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
pytestmark = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools missing")


@pytest.mark.parametrize("key", ["bam", "cram30", "cram31_normal", "cram31_small", "cram31_archive"])
def test_round_trip_preserves_sam11(key, tmp_path):
    fmt = formats.REGISTRY[key]
    ref = REPO / "python/tests/fixtures/genomic/blocks_v1_golden_ref.fa"
    if not ref.exists():
        pytest.skip("m87 reference not present; Task 3 step 3 generates it")
    enc = fmt.encode(BAM, tmp_path, ref)
    assert enc.exists() and enc.stat().st_size > 0
    dec = fmt.decode(enc, tmp_path, ref)
    assert verify.sam11_md5(dec) == verify.sam11_md5(BAM)
    assert fmt.version().startswith("samtools")
