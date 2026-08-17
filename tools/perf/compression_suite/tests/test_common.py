# tools/perf/compression_suite/tests/test_common.py
import os, sys, textwrap
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common  # noqa: E402


def test_load_manifest_reads_fields(tmp_path):
    m = tmp_path / "manifest.yaml"
    m.write_text(textwrap.dedent("""
        corpora:
          - id: toy_bam
            tier: aligned
            source: file:///x/toy.bam
            sha256: null
            reference: file:///x/ref.fa
            notes: toy
    """))
    corpora = common.load_manifest(m)
    assert [c.id for c in corpora] == ["toy_bam"]
    assert corpora[0].tier == "aligned"
    assert corpora[0].reference == "file:///x/ref.fa"


def test_run_timed_reports_wall_and_rss():
    t = common.run_timed(["sh", "-c", "python3 -c 'x=bytearray(50_000_000)'"])
    assert t.returncode == 0
    assert t.wall_s >= 0.0
    assert t.peak_rss_mb > 40


def test_sha256_of(tmp_path):
    p = tmp_path / "f"; p.write_bytes(b"abc")
    assert common.sha256_of(p) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"


def test_data_dir_env(monkeypatch, tmp_path):
    monkeypatch.setenv("TTIO_BENCH_DATA", str(tmp_path))
    assert common.data_dir() == tmp_path
