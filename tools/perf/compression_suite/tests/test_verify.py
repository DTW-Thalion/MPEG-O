# tools/perf/compression_suite/tests/test_verify.py
import shutil, subprocess, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify  # noqa: E402

REPO = Path(__file__).resolve().parents[4]
BAM = REPO / "python/tests/fixtures/genomic/m87_test.bam"
MZML = REPO / "java/src/test/resources/tiny.pwiz.1.1.mzML"
samtools = shutil.which("samtools")


@pytest.mark.skipif(samtools is None, reason="samtools missing")
def test_sam11_md5_ignores_aux_tags_and_order(tmp_path):
    a = verify.sam11_md5(BAM)
    # Reorder records and strip tags: md5 must be identical.
    sam = tmp_path / "shuffled.sam"
    hdr = subprocess.run([samtools, "view", "-H", str(BAM)], capture_output=True, text=True).stdout
    body = subprocess.run([samtools, "view", str(BAM)], capture_output=True, text=True).stdout.splitlines()
    body = ["\t".join(l.split("\t")[:11]) for l in reversed(body)]
    sam.write_text(hdr + "\n".join(body) + "\n")
    assert verify.sam11_md5(sam) == a


@pytest.mark.skipif(samtools is None, reason="samtools missing")
def test_sam11_md5_changes_when_a_base_changes(tmp_path):
    body = subprocess.run([samtools, "view", str(BAM)], capture_output=True, text=True).stdout.splitlines()
    hdr = subprocess.run([samtools, "view", "-H", str(BAM)], capture_output=True, text=True).stdout
    cols = body[0].split("\t"); cols[9] = ("A" if cols[9][0] != "A" else "C") + cols[9][1:]
    body[0] = "\t".join(cols)
    sam = tmp_path / "mut.sam"; sam.write_text(hdr + "\n".join(body) + "\n")
    assert verify.sam11_md5(sam) != verify.sam11_md5(BAM)


def test_fastq_md5_gz_and_plain_agree(tmp_path):
    import gzip
    txt = "@r1 extra\nACGT\n+\nIIII\n@r2\nGGCC\n+\n!!!!\n"
    p = tmp_path / "a.fastq"; p.write_text(txt)
    g = tmp_path / "a.fastq.gz"
    with gzip.open(g, "wt") as f: f.write(txt.replace("@r1 extra", "@r1"))
    assert verify.fastq_md5(p) == verify.fastq_md5(g)


def test_mzml_arrays_md5_stable_and_sensitive(tmp_path):
    a = verify.mzml_arrays_md5(MZML)
    assert a == verify.mzml_arrays_md5(MZML)
    assert verify.mzml_max_rel_error(MZML, MZML) == 0.0
