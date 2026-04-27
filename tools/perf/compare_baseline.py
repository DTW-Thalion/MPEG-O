#!/usr/bin/env python3
"""compare_baseline.py — V2 perf regression detector.

Reads tools/perf/baseline.json and one or more current perf result
files (matching the schema produced by profile_python_full.py and
profile_objc_full.m), computes per-metric percent deltas, and emits
a Markdown table to stdout.

Exit status:

* 0 — no metric exceeded the regression threshold (default 10%).
* 1 — at least one metric is regressed beyond threshold; fail CI.
* 2 — usage / file-not-found / parse error.

A "regression" means the new run is *slower* than the baseline by
the threshold percentage. Faster-than-baseline results are reported
as wins (negative delta) and never fail.

Usage::

    python3 tools/perf/compare_baseline.py \\
        --baseline tools/perf/baseline.json \\
        --new tools/perf/_out_python_full/full.json:python \\
        --new tools/perf/_out_objc_full/full.json:objc \\
        [--threshold 10.0] [--update-baseline]

Pass results as ``<path>:<language>`` so the script knows which
baseline section to diff against. ``--update-baseline`` rewrites
baseline.json in place with the new numbers (used by maintainers to
intentionally accept a perf change).

V2 of the verification workplan (docs/verification-workplan.md §V2).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def _flatten(prefix: str, d: dict[str, Any], out: dict[str, float | None]) -> None:
    """Flatten nested ``{group: {phase: secs}}`` into ``"group.phase" → secs``."""
    for key, value in d.items():
        full = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            _flatten(full, value, out)
        elif isinstance(value, (int, float)) or value is None:
            out[full] = value
        # ignore non-numeric / non-dict (e.g. strings like "src_mb"
        # already get included as floats)


def _load_metrics(path: Path) -> dict[str, float | None]:
    """Load a perf result file and return its flattened ``metric → secs`` dict.

    The harness JSON has shape ``{n, peaks, results: {benchmark: {phase: secs}}}``.
    We descend into ``results`` and flatten only that sub-tree so the
    ``n``/``peaks`` config keys don't pollute the metric namespace.
    """
    payload = json.loads(path.read_text())
    out: dict[str, float | None] = {}
    _flatten("", payload.get("results", {}), out)
    return out


def _load_baseline(path: Path, language: str) -> dict[str, float | None]:
    """Load the baseline section for ``language`` and flatten it."""
    payload = json.loads(path.read_text())
    if language not in payload:
        raise KeyError(
            f"baseline.json has no entry for language {language!r}; "
            f"available: {sorted(k for k in payload if not k.startswith('_'))}"
        )
    out: dict[str, float | None] = {}
    _flatten("", payload[language], out)
    return out


def compare(
    baseline: dict[str, float | None],
    new: dict[str, float | None],
    threshold_pct: float,
) -> tuple[list[tuple[str, float | None, float | None, float | None, str]], bool]:
    """Return ``(rows, has_regression)``.

    Each row is ``(metric, baseline_secs, new_secs, delta_pct, verdict)``.
    ``verdict`` is one of ``"OK"``, ``"WIN"``, ``"REGRESS"``, ``"NEW"``,
    ``"DROPPED"``. A regression sets ``has_regression = True``.

    Metrics with ``None`` values in either side are reported but never
    fail (e.g. ObjC's read-only providers expose ``null`` for the write
    half of memory/sqlite/zarr).
    """
    rows: list[tuple[str, float | None, float | None, float | None, str]] = []
    has_regression = False

    keys = sorted(set(baseline) | set(new))
    for k in keys:
        b = baseline.get(k)
        n = new.get(k)

        if k not in baseline:
            rows.append((k, None, n, None, "NEW"))
            continue
        if k not in new:
            rows.append((k, b, None, None, "DROPPED"))
            continue
        if b is None or n is None:
            rows.append((k, b, n, None, "n/a"))
            continue
        if b == 0:
            # Avoid divide-by-zero; report as no-delta.
            rows.append((k, b, n, 0.0, "OK"))
            continue

        delta_pct = (n - b) / b * 100.0
        if delta_pct >= threshold_pct:
            verdict = "REGRESS"
            has_regression = True
        elif delta_pct <= -threshold_pct:
            verdict = "WIN"
        else:
            verdict = "OK"
        rows.append((k, b, n, delta_pct, verdict))

    return rows, has_regression


def render_markdown(
    title: str,
    rows: list[tuple[str, float | None, float | None, float | None, str]],
) -> str:
    """Render a compare result as a Markdown table."""
    lines: list[str] = []
    lines.append(f"### {title}")
    lines.append("")
    lines.append("| Metric | Baseline (ms) | New (ms) | Δ% | Verdict |")
    lines.append("| --- | ---: | ---: | ---: | --- |")
    for metric, b, n, delta, verdict in rows:
        b_ms = f"{b * 1000:.2f}" if isinstance(b, (int, float)) else "—"
        n_ms = f"{n * 1000:.2f}" if isinstance(n, (int, float)) else "—"
        d_str = f"{delta:+.1f}%" if isinstance(delta, (int, float)) else "—"
        marker = {
            "REGRESS": "🔴 REGRESS",
            "WIN": "🟢 WIN",
            "OK": "OK",
            "NEW": "NEW",
            "DROPPED": "DROPPED",
            "n/a": "n/a",
        }[verdict]
        lines.append(f"| `{metric}` | {b_ms} | {n_ms} | {d_str} | {marker} |")
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="compare_baseline",
        description="Detect perf regressions vs tools/perf/baseline.json.",
    )
    parser.add_argument(
        "--baseline", type=Path,
        default=Path(__file__).parent / "baseline.json",
        help="Path to baseline.json (default: alongside this script).",
    )
    parser.add_argument(
        "--new", action="append", required=True, metavar="PATH:LANG",
        help="One or more current perf result files, each tagged with "
             "the language section to diff against (e.g. "
             "_out_python_full/full.json:python).",
    )
    parser.add_argument(
        "--threshold", type=float, default=None,
        help="Regression threshold percentage (default: read from "
             "baseline.json _meta.regression_threshold_pct, fallback 10).",
    )
    parser.add_argument(
        "--update-baseline", action="store_true",
        help="Overwrite baseline.json with the new numbers. Use only "
             "when intentionally accepting a perf change.",
    )
    args = parser.parse_args(argv)

    if not args.baseline.exists():
        print(f"baseline file not found: {args.baseline}", file=sys.stderr)
        return 2

    baseline_doc = json.loads(args.baseline.read_text())
    threshold = args.threshold
    if threshold is None:
        threshold = baseline_doc.get("_meta", {}).get(
            "regression_threshold_pct", 10.0
        )

    overall_regression = False
    sections_seen: set[str] = set()
    sections: dict[str, dict[str, Any]] = {}
    for spec in args.new:
        if ":" not in spec:
            print(f"--new must be PATH:LANG, got: {spec}", file=sys.stderr)
            return 2
        path_str, language = spec.rsplit(":", 1)
        path = Path(path_str)
        if not path.exists():
            print(f"new perf file not found: {path}", file=sys.stderr)
            return 2

        try:
            baseline_metrics = _load_baseline(args.baseline, language)
        except KeyError as exc:
            print(f"baseline error: {exc}", file=sys.stderr)
            return 2

        new_metrics = _load_metrics(path)
        rows, has_regression = compare(baseline_metrics, new_metrics, threshold)
        overall_regression = overall_regression or has_regression
        sections_seen.add(language)
        sections[language] = {"rows": rows, "path": path}

        title = f"{language} (vs baseline.json[{language}], threshold ±{threshold}%)"
        print(render_markdown(title, rows))

    if args.update_baseline:
        new_doc = dict(baseline_doc)
        for language, info in sections.items():
            new_section = json.loads(info["path"].read_text()).get("results", {})
            new_doc[language] = new_section
        args.baseline.write_text(json.dumps(new_doc, indent=2) + "\n")
        print(f"\n_baseline updated: {args.baseline}_", file=sys.stderr)

    if overall_regression:
        print(
            f"\n**FAIL** — at least one metric regressed by ≥{threshold}%.",
            flush=True,
        )
        return 1
    print(
        f"\n**OK** — no regressions above ±{threshold}%.",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
