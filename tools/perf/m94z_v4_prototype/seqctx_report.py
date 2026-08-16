"""Format the qualities-V5 bake-off grid logs as per-corpus markdown
tables with deltas vs the best mode-0 baseline. Throwaway.

Usage:
    python3 seqctx_report.py /tmp/v5bake/grid.log /tmp/v5bake/grid2.log
"""
from __future__ import annotations
import re
import sys
from collections import defaultdict

ROW = re.compile(
    r"CORPUS=(\w+) RESULT mode=(\d+) qbits=(\d+) qshift=(\d+) pbits=(\d+) "
    r"pshift=(\d+) dbits=(\d+) dshift=(\d+) sbits=(\d+) khash=(\d+) "
    r"bytes=(\d+) bq=([\d.]+) wall=([\d.]+)")


def label(m: re.Match) -> str:
    mode, qb, qs, pb, sb, kh = (int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)),
                                int(m.group(9)), int(m.group(10)))
    qsuf = f"/{qs}" if qs != 5 else ""
    if mode == 0:
        return f"m0 q{qb}{qsuf} p{pb}"
    kind = {1: f"win{sb // 2}c", 2: f"win{sb // 2}p",
            3: f"hash k{kh}>{sb}b"}[mode]
    return f"m{mode} q{qb}{qsuf} p{pb} s{sb} {kind}"


def main() -> int:
    rows: dict[str, list] = defaultdict(list)
    for path in sys.argv[1:]:
        for line in open(path, encoding="utf-8"):
            m = ROW.search(line)
            if m:
                rows[m.group(1)].append(
                    (label(m), int(m.group(11)), float(m.group(12)),
                     float(m.group(13)), int(m.group(2))))
    for corpus in ("chr22", "wes", "x250", "hifi"):
        if corpus not in rows:
            continue
        base = min((r for r in rows[corpus] if r[4] == 0),
                   key=lambda r: r[1])
        print(f"\n### {corpus} (baseline {base[0]} = {base[2]:.4f} B/q)\n")
        print("| candidate | bytes | B/q | vs base | wall s |")
        print("|---|---:|---:|---:|---:|")
        for lab, nbytes, bq, wall, _mode in sorted(
                rows[corpus], key=lambda r: r[1]):
            d = 100.0 * (nbytes - base[1]) / base[1]
            mark = "**" if nbytes < base[1] else ""
            print(f"| {mark}{lab}{mark} | {nbytes:,} | {bq:.4f} "
                  f"| {d:+.1f}% | {wall:.0f} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
