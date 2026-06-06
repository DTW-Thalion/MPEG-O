#!/usr/bin/env python3
"""Per-module coverage floor (R5).

Fail if any measured module's line coverage is below a floor (default 0.50).
Parses the coverage.xml that ``pytest --cov-report=xml`` emits. Complements
the aggregate ``--cov-fail-under`` gate by catching a single module silently
regressing to near-zero behind the total.

A small set of known-low modules is excluded (documented below); the
coverage ``omit`` list (live-daemon workbench clients) never appears in
coverage.xml, so those are excluded automatically.

Usage:
    python scripts/check_module_coverage.py coverage.xml [--min 0.50]

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET

# Known-low modules, excluded from the floor with a recorded reason.
# Matched by path suffix against each <class filename="...">.
EXCLUDES = (
    "exporters/_select.py",          # 35.9% — thin selection helper
    "workbench/transport/errors.py", # 45%  — error-type definitions
)


def module_ratios(xml_path: str) -> list[tuple[str, float, int]]:
    """Return [(filename, line_ratio, n_lines)] for every measured class."""
    root = ET.parse(xml_path).getroot()
    out = []
    for cls in root.iter("class"):
        filename = cls.get("filename", "")
        lines_el = cls.find("lines")
        if lines_el is None:
            continue
        lines = lines_el.findall("line")
        if not lines:
            continue
        hit = sum(1 for ln in lines if int(ln.get("hits", "0")) > 0)
        out.append((filename, hit / len(lines), len(lines)))
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Per-module coverage floor check.")
    p.add_argument("coverage_xml", help="path to coverage.xml")
    p.add_argument("--min", type=float, default=0.50,
                   help="minimum per-module line ratio (default 0.50)")
    args = p.parse_args(argv)

    def excluded(fn: str) -> bool:
        return any(fn.endswith(suffix) for suffix in EXCLUDES)

    violations = []
    for filename, ratio, n in module_ratios(args.coverage_xml):
        if excluded(filename):
            continue
        if ratio < args.min:
            violations.append((filename, ratio, n))

    if violations:
        print(f"Per-module coverage floor {args.min:.0%} violated:", file=sys.stderr)
        for filename, ratio, n in sorted(violations, key=lambda t: t[1]):
            print(f"  {ratio:6.1%}  ({n:4d} lines)  {filename}", file=sys.stderr)
        print(f"\n{len(violations)} module(s) below floor. "
              f"Add a test, or (if intentional) add to EXCLUDES with a reason.",
              file=sys.stderr)
        return 1

    print(f"Per-module coverage floor {args.min:.0%}: OK "
          f"(all measured modules at or above floor).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
