"""CLI entry point for the M92 compression-benchmark harness.

Examples::

    # Run all formats against the chr22 fixture, write report.
    python -m tools.benchmarks.cli run \\
        --dataset chr22_na12878 \\
        --formats bam,cram,ttio,genie \\
        --report docs/benchmarks/v1.2.0-report.md

    # Run a sweep across all datasets, machine-readable output only.
    python -m tools.benchmarks.cli run \\
        --dataset all \\
        --formats bam,cram,ttio \\
        --json-out tools/benchmarks/results.json

    # List available datasets and formats.
    python -m tools.benchmarks.cli list
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

from . import datasets as datasets_mod
from . import formats as formats_mod
from . import report as report_mod
from .runner import run_dataset


def _cmd_list(_: argparse.Namespace) -> int:
    print("Datasets:")
    for name in datasets_mod.available():
        ds = datasets_mod.get(name)
        marker = "✓" if ds.bam_path.exists() else "✗ (missing)"
        print(f"  {marker} {name}  →  {ds.bam_path}")
    print()
    print("Formats:", ", ".join(formats_mod.supported()))
    return 0


def _cmd_run(args: argparse.Namespace) -> int:
    if args.dataset == "all":
        dataset_names = datasets_mod.available()
    else:
        dataset_names = [s.strip() for s in args.dataset.split(",") if s.strip()]

    fmt_names = [s.strip() for s in args.formats.split(",") if s.strip()]
    for fmt in fmt_names:
        if fmt not in formats_mod.supported():
            print(f"error: unknown format {fmt!r}. Supported: "
                  f"{', '.join(formats_mod.supported())}", file=sys.stderr)
            return 2

    work_dir = Path(args.work_dir).resolve()
    summaries = []
    for name in dataset_names:
        ds = datasets_mod.get(name)
        print(f"[bench] {name}: running {','.join(fmt_names)}…", file=sys.stderr)
        summary = run_dataset(ds, fmt_names, work_dir / name)
        summaries.append(summary)

    if args.json_out:
        Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json_out).write_text(
            json.dumps([asdict(s) for s in summaries], indent=2, default=str)
        )
        print(f"[bench] wrote {args.json_out}", file=sys.stderr)

    if args.report:
        report_mod.write(summaries, Path(args.report), title=args.report_title)
        print(f"[bench] wrote {args.report}", file=sys.stderr)

    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="m92-bench", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="list datasets and formats")
    p_list.set_defaults(func=_cmd_list)

    p_run = sub.add_parser("run", help="run benchmarks")
    p_run.add_argument(
        "--dataset", required=True,
        help="dataset name, comma-separated list, or 'all'",
    )
    p_run.add_argument(
        "--formats", default="bam,cram,ttio,genie",
        help="comma-separated format names (bam,cram,ttio,genie)",
    )
    p_run.add_argument(
        "--work-dir", default="tools/benchmarks/_work",
        help="scratch directory for compressed/decompressed outputs",
    )
    p_run.add_argument(
        "--json-out", default=None,
        help="write machine-readable summary JSON to this path",
    )
    p_run.add_argument(
        "--report", default=None,
        help="write Markdown report to this path",
    )
    p_run.add_argument(
        "--report-title", default="TTI-O v1.2.0 Compression Benchmark",
        help="report title",
    )
    p_run.set_defaults(func=_cmd_run)

    args = p.parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
