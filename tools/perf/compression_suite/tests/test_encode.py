# tools/perf/compression_suite/tests/test_encode.py
import json, shutil, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common  # noqa: E402
from stages import prepare, encode  # noqa: E402

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
pytestmark = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools missing")


def test_encode_writes_verified_results_and_resumes(tmp_path, monkeypatch, REF):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    monkeypatch.setattr(encode, "RESULTS", tmp_path / "results")
    c = common.Corpus(id="toy", tier="aligned", source=f"file://{BAM}", sha256=None, reference=f"file://{REF}")
    prepare.run([c])
    assert encode.run([c], "bam,cram31_small,ttio", smoke=True) == 0
    files = sorted((tmp_path / "results/toy").glob("*.json"))
    assert files, "no results written"
    recs = [json.loads(f.read_text()) for f in files]
    assert {r["format"] for r in recs} >= {"bam", "cram31_small", "ttio"}
    assert all(r["verify"] == "PASS" for r in recs)
    assert all(r["output_bytes"] > 0 and r["encode_s"] >= 0 for r in recs)
    ttio = [r for r in recs if r["format"] == "ttio"]
    assert all(r["kind"] == "bam11" for r in ttio)
    # second run reuses everything
    mtimes = {f: f.stat().st_mtime_ns for f in files}
    assert encode.run([c], "bam,cram31_small,ttio", smoke=True) == 0
    assert {f: f.stat().st_mtime_ns for f in files} == mtimes


def test_failed_verify_is_recorded_not_raised(tmp_path, monkeypatch, REF):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    monkeypatch.setattr(encode, "RESULTS", tmp_path / "results")
    import verify
    monkeypatch.setattr(verify, "sam11_md5", lambda p: str(p))  # every decode differs from input
    c = common.Corpus(id="toy", tier="aligned", source=f"file://{BAM}", sha256=None, reference=f"file://{REF}")
    prepare.run([c])
    assert encode.run([c], "bam", smoke=True) == 0
    rec = json.loads(next((tmp_path / "results/toy").glob("bam.*.json")).read_text())
    assert rec["verify"] == "FAIL"
