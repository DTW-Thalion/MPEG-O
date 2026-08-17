# tools/perf/compression_suite/tests/test_prepare.py
import json, shutil, subprocess, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common, verify  # noqa: E402
from stages import prepare  # noqa: E402

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
pytestmark = pytest.mark.skipif(shutil.which("samtools") is None, reason="samtools missing")


def test_eleven_column_strips_tags_keeps_header(tmp_path):
    out = prepare.eleven_column(BAM, tmp_path / "x.11col.bam")
    body = subprocess.run(["samtools", "view", str(out)], capture_output=True, text=True).stdout
    assert all(len(l.split("\t")) == 11 for l in body.splitlines())
    hdr = subprocess.run(["samtools", "view", "-H", str(out)], capture_output=True, text=True).stdout
    assert "@SQ" in hdr
    assert verify.sam11_md5(out) == verify.sam11_md5(BAM)


def test_fastq_plain_decompresses_gz(tmp_path):
    import gzip
    text = "".join(f"@r{i}\nACGT\n+\nIIII\n" for i in range(7))
    src = tmp_path / "in.fastq.gz"
    with gzip.open(src, "wt") as f:
        f.write(text)
    out = prepare.fastq_plain(src, tmp_path / "in.fastq")
    assert out.read_text() == text
    plain = tmp_path / "p.fastq"; plain.write_text(text)
    assert prepare.fastq_plain(plain, tmp_path / "p2.fastq").read_text() == text


def test_run_writes_plan(tmp_path, monkeypatch):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    c = common.Corpus(id="toy", tier="aligned", source=f"file://{BAM}", sha256=None,
                      reference=f"file://{REPO}/python/tests/fixtures/genomic/blocks_v1_golden_ref.fa")
    assert prepare.run([c]) == 0
    plan = json.loads((tmp_path / "prepared/toy/plan.json").read_text())
    kinds = {s["kind"] for s in plan["inputs"]}
    assert kinds == {"bam11", "bam_full"}
    assert len(plan["inputs"]) == 2
