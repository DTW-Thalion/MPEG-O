# tools/perf/compression_suite/tests/test_report.py
import json, sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import report  # noqa: E402


def _rec(**kw):
    base = {"corpus": "toy", "tier": "aligned", "format": "bam", "input": "toy", "kind": "bam11",
            "input_bytes": 100, "output_bytes": 50, "encode_s": 1.0, "decode_s": 0.5,
            "encode_rss_mb": 10.0, "decode_rss_mb": 5.0, "verify": "PASS", "max_rel_error": None,
            "tool_version": "samtools 1.19.2", "input_sha256": "x", "lossy": False, "breakdown": {},
            "bases": 1000}
    base.update(kw); return base


def test_aggregate_keeps_one_row_per_format_and_flags_fail(tmp_path):
    d = tmp_path / "toy"; d.mkdir()
    (d / "bam.bam11.json").write_text(json.dumps(_rec(output_bytes=80)))
    (d / "bam.bam_full.json").write_text(json.dumps(_rec(kind="bam_full", output_bytes=120)))
    (d / "ttio.bam11.json").write_text(json.dumps(_rec(format="ttio", output_bytes=20, verify="FAIL",
                                                        verify_note="columns differing: TLEN in 4")))
    agg = report.aggregate(tmp_path)
    assert agg["toy"][("bam", "bam11")].output_bytes == 80
    assert agg["toy"][("bam", "bam_full")].output_bytes == 120
    assert agg["toy"][("bam", "bam11")].verify == "PASS"
    assert agg["toy"][("ttio", "bam11")].verify == "FAIL"
    md = report.render(agg, {"cpu": "x", "date": "2026-08-16"})
    assert "| ttio" in md and "FAIL" in md
    assert "80" in md
    assert "Rows that failed verification" in md and "TLEN in 4" in md
    # the failed row shows no size in the per-corpus table, only in the failed-rows table
    assert "| ttio | bam11 |  |" in md
    # ratio column: bam is the baseline -> 1.00
    assert "1.00" in md
