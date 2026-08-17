# tools/perf/compression_suite/suite.py
"""Compression benchmark suite driver: fetch | prepare | encode | report."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import common  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="suite.py")
    ap.add_argument("--manifest", default=str(HERE / "manifest.yaml"))
    ap.add_argument("--corpus", action="append", default=None,
                    help="restrict to these corpus ids (repeatable)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("fetch")
    sub.add_parser("prepare")
    pe = sub.add_parser("encode")
    pe.add_argument("--formats", default="all",
                    help="comma list of format keys or 'all'")
    pe.add_argument("--smoke", action="store_true",
                    help="on-disk corpora only")
    sub.add_parser("report")
    args = ap.parse_args(argv)
    corpora = common.load_manifest(Path(args.manifest))
    if args.corpus:
        corpora = [c for c in corpora if c.id in set(args.corpus)]
    if args.cmd == "fetch":
        from stages import fetch; return fetch.run(corpora, Path(args.manifest))
    if args.cmd == "prepare":
        from stages import prepare; return prepare.run(corpora)
    if args.cmd == "encode":
        from stages import encode; return encode.run(corpora, args.formats, args.smoke)
    if args.cmd == "report":
        import report; return report.run(HERE / "results", HERE / "REPORT.md")
    return 2


if __name__ == "__main__":
    sys.exit(main())
