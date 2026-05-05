"""FASTQ export CLI — emits a genomic run as a FASTQ file.

Usage
-----
::

    python -m ttio.tools.fastq_export_cli \\
        --in study.tio --name genomic_0001 --out reads.fq.gz

Exit codes
----------
- ``0`` — wrote output successfully.
- ``1`` — argument error.
- ``2`` — read / write failure.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from ..exporters.fastq import FastqWriter
from ..spectral_dataset import SpectralDataset


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ttio.tools.fastq_export_cli",
        description="Export FASTQ from a .tio container.",
    )
    p.add_argument("--in", dest="in_path", required=True, type=Path)
    p.add_argument("--name", required=True,
                   help="genomic-run name under /study/genomic_runs/")
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--phred", type=int, choices=(33, 64), default=33,
                   help="output Phred offset (default: 33)")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)

    try:
        with SpectralDataset.open(args.in_path) as ds:
            run = ds.genomic_runs[args.name]
            n_reads = len(run)
            FastqWriter.write(run, args.out, phred_offset=args.phred)
        print(
            f"wrote run {args.name!r} ({n_reads} reads, "
            f"Phred+{args.phred}) to {args.out}"
        )
        return 0
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except KeyError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
