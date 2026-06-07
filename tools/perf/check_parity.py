#!/usr/bin/env python3
"""check_parity.py — cross-SDK perf-parity detector.

Reads tools/perf/baseline.json and, for every timing metric present in
ALL THREE SDK sections (``python``/``java``/``objc``), computes the
cross-SDK ratio ``max(ms) / min(ms)`` and flags metrics whose ratio is
large enough to warrant a manual parity review.

The three harnesses benchmark the same operations but nothing otherwise
checks whether they perform *comparably*. Several metrics differ by
100-700x across SDKs — some legitimate (ObjC ``import.bam`` spawns
samtools via NSTask while Java uses in-process htsjdk), some meaningless
(sub-µs metrics where the fastest SDK rounds to ~0ms), and some genuine
concerns (Python ``streaming.read`` vs Java; ``ms.sqlite.read``;
``transport.plain.encode``). This tool surfaces them for triage.

Rules (mirrors compare_baseline.py's _meta-driven config):

1. ``ratio = max(value) / min(value)`` across the 3 SDKs. Values in
   baseline.json are seconds; the ratio is unit-independent (display is
   x1000 for ms).
2. **Absolute floor on the MIN:** if ``min(value) * 1000 < min_abs_ms``
   (``_meta.min_abs_ms``, default 5.0), the fastest SDK is below the
   floor and a large ratio is meaningless — report ``below-floor`` and
   never flag.
3. **Allow-list:** ``_meta.parity_allow`` maps metric -> reason for a
   known, legitimate cross-SDK gap. Reported with the reason, never
   flagged.
4. **Flag:** any remaining metric whose ratio >=
   ``_meta.parity_ratio_threshold`` (default 10.0) that is above the
   floor and not allow-listed.

``*_mb`` size metrics are excluded (they are payload sizes, not timings).

Exit status:

* 0 — no un-allow-listed, above-floor metric exceeds the threshold.
* 1 — at least one parity outlier flagged; fail the manual review gate.
* 2 — usage / file-not-found / parse error.

Usage::

    python3 tools/perf/check_parity.py [--baseline tools/perf/baseline.json]
                                       [--threshold 10.0]

NOT a CI gate — run manually alongside the rest of the perf suite. See
tools/perf/run_perf_ci.sh header.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

_SDKS = ("python", "java", "objc")


def _flatten(prefix: str, d: dict[str, Any], out: dict[str, float | None]) -> None:
    """Flatten nested ``{group: {phase: secs}}`` into ``"group.phase" → secs``."""
    for key, value in d.items():
        full = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            _flatten(full, value, out)
        elif isinstance(value, (int, float)) or value is None:
            out[full] = value


def _load_section(payload: dict[str, Any], language: str) -> dict[str, float | None]:
    """Flatten one SDK section of an already-parsed baseline document."""
    if language not in payload:
        raise KeyError(
            f"baseline.json has no entry for language {language!r}; "
            f"available: {sorted(k for k in payload if not k.startswith('_'))}"
        )
    out: dict[str, float | None] = {}
    _flatten("", payload[language], out)
    return out


def check(
    sections: dict[str, dict[str, float | None]],
    threshold: float,
    min_abs_ms: float = 5.0,
    allow: dict[str, str] | None = None,
) -> tuple[list[tuple[str, float, float, float, float, str]], bool]:
    """Return ``(rows, has_flag)``.

    Each row is ``(metric, py_secs, java_secs, objc_secs, ratio, verdict)``.
    ``verdict`` is one of ``"OK"``, ``"below-floor"``,
    ``"allow-listed:<reason>"``, ``"FLAG"``. A ``"FLAG"`` sets
    ``has_flag = True``.

    Only metrics present (non-None, numeric) in ALL THREE SDK sections are
    considered. ``*_mb`` size metrics are excluded. Rows are sorted by
    ratio descending.
    """
    allow = allow or {}
    floor_secs = min_abs_ms / 1000.0
    rows: list[tuple[str, float, float, float, float, str]] = []
    has_flag = False

    common = set(sections[_SDKS[0]])
    for sdk in _SDKS[1:]:
        common &= set(sections[sdk])

    for metric in common:
        if metric.endswith("_mb"):
            continue
        vals = [sections[sdk][metric] for sdk in _SDKS]
        if any(v is None for v in vals):
            continue
        py, java, objc = (float(v) for v in vals)  # type: ignore[arg-type]
        lo = min(py, java, objc)
        hi = max(py, java, objc)
        ratio = hi / lo if lo > 0 else float("inf")

        if lo < floor_secs:
            verdict = "below-floor"
        elif metric in allow:
            verdict = f"allow-listed:{allow[metric]}"
        elif ratio >= threshold:
            verdict = "FLAG"
            has_flag = True
        else:
            verdict = "OK"
        rows.append((metric, py, java, objc, ratio, verdict))

    rows.sort(key=lambda r: r[4], reverse=True)
    return rows, has_flag


def render_markdown(
    title: str,
    rows: list[tuple[str, float, float, float, float, str]],
) -> str:
    """Render a parity result as a Markdown table."""
    lines: list[str] = []
    lines.append(f"### {title}")
    lines.append("")
    lines.append("| Metric | python ms | java ms | objc ms | ratio | Verdict |")
    lines.append("| --- | ---: | ---: | ---: | ---: | --- |")
    for metric, py, java, objc, ratio, verdict in rows:
        if verdict == "FLAG":
            marker = "🔴 FLAG"
        elif verdict == "below-floor":
            marker = "below-floor"
        elif verdict.startswith("allow-listed:"):
            marker = f"allow-listed: {verdict.split(':', 1)[1]}"
        else:
            marker = "OK"
        ratio_str = f"{ratio:.1f}x" if ratio != float("inf") else "∞"
        lines.append(
            f"| `{metric}` | {py * 1000:.2f} | {java * 1000:.2f} | "
            f"{objc * 1000:.2f} | {ratio_str} | {marker} |"
        )
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="check_parity",
        description="Flag cross-SDK timing outliers in tools/perf/baseline.json.",
    )
    parser.add_argument(
        "--baseline", type=Path,
        default=Path(__file__).parent / "baseline.json",
        help="Path to baseline.json (default: alongside this script).",
    )
    parser.add_argument(
        "--threshold", type=float, default=None,
        help="Cross-SDK ratio threshold (default: read from baseline.json "
             "_meta.parity_ratio_threshold, fallback 10.0).",
    )
    args = parser.parse_args(argv)

    if not args.baseline.exists():
        print(f"baseline file not found: {args.baseline}", file=sys.stderr)
        return 2

    try:
        payload = json.loads(args.baseline.read_text())
    except json.JSONDecodeError as exc:
        print(f"could not parse {args.baseline}: {exc}", file=sys.stderr)
        return 2

    meta = payload.get("_meta", {})
    threshold = args.threshold
    if threshold is None:
        threshold = meta.get("parity_ratio_threshold", 10.0)
    min_abs_ms = meta.get("min_abs_ms", 5.0)
    allow = meta.get("parity_allow", {})

    try:
        sections = {sdk: _load_section(payload, sdk) for sdk in _SDKS}
    except KeyError as exc:
        print(f"baseline error: {exc}", file=sys.stderr)
        return 2

    rows, has_flag = check(sections, threshold, min_abs_ms, allow)

    title = (
        f"cross-SDK parity (ratio = max/min ms, threshold >={threshold}x, "
        f"floor {min_abs_ms}ms, {len(allow)} allow-listed)"
    )
    print(render_markdown(title, rows))

    n_flag = sum(1 for r in rows if r[5] == "FLAG")
    n_allow = sum(1 for r in rows if r[5].startswith("allow-listed:"))
    n_floor = sum(1 for r in rows if r[5] == "below-floor")
    n_ok = sum(1 for r in rows if r[5] == "OK")
    print(
        f"Summary: {len(rows)} comparable metrics — {n_ok} OK, "
        f"{n_floor} below-floor, {n_allow} allow-listed, {n_flag} FLAGGED."
    )

    if has_flag:
        print(
            f"\n**FAIL** — {n_flag} un-allow-listed above-floor metric(s) "
            f"exceed the {threshold}x cross-SDK ratio.",
            flush=True,
        )
        return 1
    print(
        f"\n**OK** — no un-allow-listed above-floor metric exceeds {threshold}x.",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
