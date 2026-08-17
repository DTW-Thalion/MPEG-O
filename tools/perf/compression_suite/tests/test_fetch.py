# tools/perf/compression_suite/tests/test_fetch.py
import sys, textwrap
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common  # noqa: E402
from stages import fetch  # noqa: E402


def test_fetch_local_file_records_sha_and_enforces(tmp_path, monkeypatch):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    src = tmp_path / "src.bin"; src.write_bytes(b"hello")
    m = tmp_path / "manifest.yaml"
    m.write_text(textwrap.dedent(f"""
        corpora:
          - id: toy
            tier: ms
            source: file://{src}
            sha256: null
            reference: null
    """))
    corpora = common.load_manifest(m)
    assert fetch.run(corpora, m) == 0
    again = common.load_manifest(m)
    assert again[0].sha256 == common.sha256_of(src)
    src.write_bytes(b"changed")
    with pytest.raises(RuntimeError, match="sha256 mismatch"):
        fetch.run(again, m)


def test_http_fetch_uses_curl_resume(monkeypatch, tmp_path):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    calls = []
    monkeypatch.setattr(fetch, "_curl", lambda url, dest: (calls.append((url, dest)), dest.write_bytes(b"x")))
    c = common.Corpus(id="h", tier="ms", source="https://example.org/a.mzML", sha256=None, reference=None)
    m = tmp_path / "m.yaml"; m.write_text("corpora:\n  - id: h\n    tier: ms\n    source: https://example.org/a.mzML\n")
    assert fetch.run([c], m) == 0
    assert calls and calls[0][1].name == "a.mzML.part"
    assert (tmp_path / "raw/h/a.mzML").exists()


def test_reference_lands_as_id_fa_with_fai(monkeypatch, tmp_path):
    import gzip, shutil
    if shutil.which("samtools") is None:
        pytest.skip("samtools missing")
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    fa = ">chr1\nACGTACGTAC\n>chr2\nGGGGCCCC\n"
    monkeypatch.setattr(fetch, "_curl", lambda url, dest: dest.write_bytes(gzip.compress(fa.encode())))
    c = common.Corpus(id="toyref", tier="reference", source="https://example.org/toy.fna.gz", sha256=None, reference=None)
    m = tmp_path / "m.yaml"; m.write_text("corpora:\n  - id: toyref\n    tier: reference\n    source: https://example.org/toy.fna.gz\n")
    assert fetch.run([c], m) == 0
    out = tmp_path / "raw/reference/toyref.fa"
    assert out.read_text() == fa
    assert (tmp_path / "raw/reference/toyref.fa.fai").exists()
    assert (tmp_path / "raw/reference/toy.fna.gz").exists()
