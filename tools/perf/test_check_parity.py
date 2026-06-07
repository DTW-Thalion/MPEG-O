#!/usr/bin/env python3
"""Tests for tools/perf/check_parity.py — the cross-SDK perf-parity detector.

Covers the ratio math, the absolute floor (a sub-floor metric never flags even
at a huge ratio), the allow-list (an allow-listed huge-ratio metric never
flags), and the threshold (an above-floor non-allow-listed metric at/over the
threshold flags; one under does not).

Run: ``python3 -m pytest tools/perf/test_check_parity.py -v``
(or plain ``python3 tools/perf/test_check_parity.py`` for a smoke run).
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import check_parity as cp  # noqa: E402


def _row(rows, metric):
    for r in rows:
        if r[0] == metric:
            return r
    raise AssertionError(f"metric {metric!r} not in rows")


def _verdict(rows, metric):
    return _row(rows, metric)[5]


def _sections(py, java, objc):
    """Build the three flattened SDK sections from per-metric dicts."""
    return {"python": dict(py), "java": dict(java), "objc": dict(objc)}


def test_ratio_math_is_max_over_min():
    """ratio = max(value)/min(value) across the 3 SDKs, regardless of order."""
    secs = _sections(
        {"x": 0.100},   # 100ms (max)
        {"x": 0.010},   # 10ms (min)
        {"x": 0.050},   # 50ms
    )
    rows, _ = cp.check(secs, threshold=10.0, min_abs_ms=5.0)
    metric, py, java, objc, ratio, verdict = _row(rows, "x")
    assert abs(ratio - 10.0) < 1e-9
    # py/java/objc carried through in fixed order
    assert (py, java, objc) == (0.100, 0.010, 0.050)


def test_subfloor_metric_never_flags_even_at_huge_ratio():
    """When the fastest SDK is below the floor, a huge ratio is meaningless and
    must be reported below-floor, never flagged."""
    secs = _sections(
        {"tiny": 0.0005},   # 0.5ms — min, below 5ms floor
        {"tiny": 0.500},    # 500ms — 1000x ratio
        {"tiny": 0.001},
    )
    rows, has_flag = cp.check(secs, threshold=10.0, min_abs_ms=5.0)
    assert _verdict(rows, "tiny") == "below-floor"
    assert has_flag is False


def test_allow_listed_metric_never_flags_even_at_huge_ratio():
    """An above-floor metric on the allow-list is reported with its reason and
    never flagged, no matter how large the ratio."""
    secs = _sections(
        {"import.bam": 0.006},    # 6ms min, above floor
        {"import.bam": 0.700},
        {"import.bam": 0.600},    # ~117x ratio
    )
    allow = {"import.bam": "ObjC spawns samtools via NSTask"}
    rows, has_flag = cp.check(secs, threshold=10.0, min_abs_ms=5.0, allow=allow)
    verdict = _verdict(rows, "import.bam")
    assert verdict.startswith("allow-listed:")
    assert "samtools" in verdict
    assert has_flag is False


def test_above_floor_non_allowlisted_over_threshold_flags():
    """An above-floor, non-allow-listed metric at/over the threshold flags."""
    secs = _sections(
        {"streaming.write": 0.900},   # 900ms max
        {"streaming.write": 0.010},   # 10ms min, above floor -> 90x
        {"streaming.write": 0.500},
    )
    rows, has_flag = cp.check(secs, threshold=10.0, min_abs_ms=5.0)
    assert _verdict(rows, "streaming.write") == "FLAG"
    assert has_flag is True


def test_above_floor_under_threshold_does_not_flag():
    """An above-floor metric whose ratio is under the threshold is OK."""
    secs = _sections(
        {"genomic.write": 0.090},   # 90ms max
        {"genomic.write": 0.010},   # 10ms min -> 9x, under 10x
        {"genomic.write": 0.050},
    )
    rows, has_flag = cp.check(secs, threshold=10.0, min_abs_ms=5.0)
    assert _verdict(rows, "genomic.write") == "OK"
    assert has_flag is False


def test_threshold_is_inclusive():
    """ratio exactly at the threshold flags (>=, not >)."""
    secs = _sections(
        {"m": 0.100},   # 100ms
        {"m": 0.010},   # 10ms -> exactly 10x, both above 5ms floor
        {"m": 0.050},
    )
    rows, has_flag = cp.check(secs, threshold=10.0, min_abs_ms=5.0)
    assert _verdict(rows, "m") == "FLAG"
    assert has_flag is True


def test_size_metrics_excluded():
    """``*_mb`` payload-size metrics are not timings and must be skipped."""
    secs = _sections(
        {"transport.plain.src_mb": 2.79, "t": 0.020},
        {"transport.plain.src_mb": 2.74, "t": 0.010},
        {"transport.plain.src_mb": 2.74, "t": 0.015},
    )
    rows, _ = cp.check(secs, threshold=10.0, min_abs_ms=5.0)
    metrics = {r[0] for r in rows}
    assert "transport.plain.src_mb" not in metrics
    assert "t" in metrics


def test_only_metrics_common_to_all_three_sdks():
    """A metric missing from one SDK (or None there) is not comparable."""
    secs = _sections(
        {"common": 0.020, "py_only": 0.020, "has_none": 0.020},
        {"common": 0.010, "has_none": None},
        {"common": 0.015, "has_none": 0.010},
    )
    rows, _ = cp.check(secs, threshold=10.0, min_abs_ms=5.0)
    metrics = {r[0] for r in rows}
    assert "common" in metrics
    assert "py_only" not in metrics      # absent from java/objc
    assert "has_none" not in metrics     # None in java


def test_rows_sorted_by_ratio_desc():
    secs = _sections(
        {"big": 0.200, "small": 0.012},
        {"big": 0.010, "small": 0.010},   # big 20x, small 1.2x
        {"big": 0.050, "small": 0.011},
    )
    rows, _ = cp.check(secs, threshold=10.0, min_abs_ms=5.0)
    ratios = [r[4] for r in rows]
    assert ratios == sorted(ratios, reverse=True)


if __name__ == "__main__":
    import traceback
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except Exception:  # noqa: BLE001
            failed += 1
            print(f"FAIL {fn.__name__}")
            traceback.print_exc()
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    sys.exit(1 if failed else 0)
