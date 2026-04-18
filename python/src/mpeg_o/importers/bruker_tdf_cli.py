"""CLI wrapper for :mod:`mpeg_o.importers.bruker_tdf` — invoked by the
Java ``BrukerTDFReader`` and Objective-C ``MPGOBrukerTDFReader`` via
subprocess. Not intended for direct user use; callers should prefer
the in-process Python API.

Usage::

    python -m mpeg_o.importers.bruker_tdf_cli \\
        --input path/to/analysis.d \\
        --output path/to/target.mpgo [--title "Run 1"] [--ms2]

Exit codes:
  0  — success.
  2  — argument error.
  3  — ``opentimspy`` not importable; install ``mpeg-o[bruker]``.
  4  — I/O error (missing ``.d``, malformed SQLite, cannot write output).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m mpeg_o.importers.bruker_tdf_cli",
        description="Import a Bruker timsTOF .d directory into a .mpgo file.")
    p.add_argument("--input", required=True,
                    help="Bruker .d directory (contains analysis.tdf).")
    p.add_argument("--output", required=True,
                    help="Target .mpgo file path.")
    p.add_argument("--title", default=None,
                    help="Study title (defaults to .d stem).")
    p.add_argument("--ms2", action="store_true",
                    help="Include MS2 frames as a second run (default MS1 only).")
    args = p.parse_args(argv)

    from .bruker_tdf import BrukerTDFUnavailableError, read
    try:
        out = read(Path(args.input), Path(args.output),
                    title=args.title, ms2=args.ms2)
    except BrukerTDFUnavailableError as e:
        print(str(e), file=sys.stderr)
        return 3
    except (FileNotFoundError, OSError, RuntimeError, ValueError) as e:
        print(f"bruker_tdf: {e}", file=sys.stderr)
        return 4
    print(str(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
