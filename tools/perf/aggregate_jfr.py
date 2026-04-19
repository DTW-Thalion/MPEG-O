"""Aggregate JFR sample counts by topmost method (hot leaf).

Parses the output of `jfr print --events jdk.ExecutionSample` or
`jdk.NativeMethodSample` and counts the frequency of the top-of-stack
method across all samples.
"""
from __future__ import annotations

import sys
from collections import Counter
from pathlib import Path


def parse(path: Path) -> Counter[str]:
    counts: Counter[str] = Counter()
    lines = path.read_text().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("stackTrace = ["):
            j = i + 1
            top = lines[j].strip()
            # Strip trailing " line: NNN" for grouping
            top = top.split(" line:")[0]
            counts[top] += 1
            # Skip forward until "]" closes the stack trace
            while j < len(lines) and not lines[j].strip().startswith("]"):
                j += 1
            i = j
        i += 1
    return counts


def parse_with_immediate_caller(path: Path) -> Counter[str]:
    counts: Counter[str] = Counter()
    lines = path.read_text().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("stackTrace = ["):
            top = lines[i + 1].strip().split(" line:")[0]
            caller = ""
            if i + 2 < len(lines):
                c = lines[i + 2].strip()
                if c and not c.startswith("]"):
                    caller = c.split(" line:")[0]
            counts[f"{top}  <- {caller}"] += 1
            j = i + 1
            while j < len(lines) and not lines[j].strip().startswith("]"):
                j += 1
            i = j
        i += 1
    return counts


def main() -> int:
    for arg in sys.argv[1:]:
        path = Path(arg)
        if not path.exists() or path.stat().st_size == 0:
            print(f"{path}: missing or empty")
            continue
        print(f"=== {path.name} (leaf method counts) ===")
        cc = parse(path)
        total = sum(cc.values())
        print(f"(total samples: {total})")
        for method, n in cc.most_common(20):
            pct = 100.0 * n / total if total else 0.0
            print(f"  {n:5d}  {pct:5.1f}%  {method}")
        print()
        print(f"=== {path.name} (leaf <- caller, top 15) ===")
        pair = parse_with_immediate_caller(path)
        for pm, n in pair.most_common(15):
            pct = 100.0 * n / total if total else 0.0
            print(f"  {n:5d}  {pct:5.1f}%  {pm}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
