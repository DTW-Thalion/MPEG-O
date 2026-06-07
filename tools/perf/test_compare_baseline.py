#!/usr/bin/env python3
"""Tests for tools/perf/compare_baseline.py — focus on the absolute-floor
(``min_abs_ms``) regression-suppression behaviour added in perf P1a.

Run: ``python3 -m pytest tools/perf/test_compare_baseline.py -v``
(or plain ``python3 tools/perf/test_compare_baseline.py`` for a smoke run).
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import compare_baseline as cb  # noqa: E402


def _verdict(rows, metric):
    for k, b, n, d, v in rows:
        if k == metric:
            return v
    raise AssertionError(f"metric {metric!r} not in rows")


def test_tiny_metric_noise_does_not_regress_with_floor():
    """A sub-floor metric that doubles (e.g. 1.7ms -> 3.4ms, +100%) must NOT
    fail the gate when both sides are below the absolute floor."""
    baseline = {"streaming.read": 0.0017}
    new = {"streaming.read": 0.0034}
    rows, has_reg = cb.compare(baseline, new, threshold_pct=15.0, min_abs_ms=5.0)
    assert has_reg is False
    assert _verdict(rows, "streaming.read") == "small"


def test_tiny_metric_noise_DOES_regress_without_floor():
    """With no floor (default 0), the old behaviour is preserved — tiny-metric
    noise still trips the gate. Guards against silently changing defaults."""
    baseline = {"streaming.read": 0.0017}
    new = {"streaming.read": 0.0034}
    rows, has_reg = cb.compare(baseline, new, threshold_pct=15.0, min_abs_ms=0.0)
    assert has_reg is True
    assert _verdict(rows, "streaming.read") == "REGRESS"


def test_real_jump_above_floor_still_regresses():
    """A metric that jumps from below the floor to well above it is a genuine
    regression and must still fail — the floor only suppresses when BOTH sides
    are below it."""
    baseline = {"codecs.x": 0.001}      # 1ms, below floor
    new = {"codecs.x": 0.100}           # 100ms, far above floor
    rows, has_reg = cb.compare(baseline, new, threshold_pct=25.0, min_abs_ms=5.0)
    assert has_reg is True
    assert _verdict(rows, "codecs.x") == "REGRESS"


def test_substantial_metric_regression_not_suppressed():
    """The floor must not suppress regressions on metrics above the floor."""
    baseline = {"transport.plain.encode": 0.200}   # 200ms
    new = {"transport.plain.encode": 0.300}         # 300ms, +50%
    rows, has_reg = cb.compare(baseline, new, threshold_pct=25.0, min_abs_ms=5.0)
    assert has_reg is True
    assert _verdict(rows, "transport.plain.encode") == "REGRESS"


def test_substantial_metric_within_threshold_ok():
    baseline = {"genomic.write": 0.900}
    new = {"genomic.write": 1.000}                  # +11%, under 25%
    rows, has_reg = cb.compare(baseline, new, threshold_pct=25.0, min_abs_ms=5.0)
    assert has_reg is False
    assert _verdict(rows, "genomic.write") == "OK"


def test_override_loosens_threshold_for_noisy_metric():
    """A metric on the override list gets its own (looser) threshold: a drift
    above the tight global but below its override must NOT fail."""
    overrides = {"ms.zarr.read": 50.0}
    baseline = {"ms.zarr.read": 0.035, "codecs.x": 0.020}
    new = {"ms.zarr.read": 0.049, "codecs.x": 0.020}   # zarr +40%, under its 50%
    rows, has_reg = cb.compare(
        baseline, new, threshold_pct=20.0, min_abs_ms=5.0, overrides=overrides
    )
    assert has_reg is False
    assert _verdict(rows, "ms.zarr.read") == "OK"


def test_override_still_catches_regression_beyond_its_threshold():
    """An override only loosens the threshold; a drift beyond the override
    value is still a regression."""
    overrides = {"ms.zarr.read": 50.0}
    baseline = {"ms.zarr.read": 0.035}
    new = {"ms.zarr.read": 0.060}                       # +71%, over its 50%
    rows, has_reg = cb.compare(
        baseline, new, threshold_pct=20.0, min_abs_ms=5.0, overrides=overrides
    )
    assert has_reg is True
    assert _verdict(rows, "ms.zarr.read") == "REGRESS"


def test_non_override_metric_uses_tight_global():
    """A metric NOT on the override list is gated at the tight global
    threshold, so a 40% drift fails."""
    overrides = {"ms.zarr.read": 50.0}
    baseline = {"codecs.delta_rans_decode": 0.020}
    new = {"codecs.delta_rans_decode": 0.028}           # +40%, over global 20%
    rows, has_reg = cb.compare(
        baseline, new, threshold_pct=20.0, min_abs_ms=5.0, overrides=overrides
    )
    assert has_reg is True
    assert _verdict(rows, "codecs.delta_rans_decode") == "REGRESS"


def test_floor_default_is_zero():
    """compare() defaults min_abs_ms=0 so callers that don't pass it get the
    historical behaviour."""
    baseline = {"m": 0.0017}
    new = {"m": 0.0034}
    rows, has_reg = cb.compare(baseline, new, threshold_pct=15.0)
    assert has_reg is True


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
