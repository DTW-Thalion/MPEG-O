"""FASTQ import CLI — converts a FASTQ file into an unaligned
genomic run inside a ``.tio`` container.

Usage
-----
::

    python -m ttio.tools.fastq_import_cli \\
        --fastq reads.fq.gz --out study.tio --sample S1

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

from ..importers.fastq import FastqParseError, FastqReader
from ..spectral_dataset import SpectralDataset


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ttio.tools.fastq_import_cli",
        description="Import FASTQ into a .tio container.",
    )
    p.add_argument("--fastq", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--name", default="genomic_0001")
    p.add_argument("--sample", default="")
    p.add_argument("--platform", default="")
    p.add_argument("--phred", type=int, choices=(33, 64), default=None,
                   help="force Phred offset (default: auto-detect)")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)

    try:
        reader = FastqReader(args.fastq, force_phred=args.phred)
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    try:
        run = reader.read(
            sample_name=args.sample, platform=args.platform,
        )
        SpectralDataset.write_minimal(
            args.out,
            title="",
            isa_investigation_id="",
            runs={},
            genomic_runs={args.name: run},
        )
        print(
            f"wrote unaligned run {args.name!r} "
            f"({len(run.read_names)} reads, "
            f"Phred+{reader.detected_phred_offset}) to {args.out}"
        )
        return 0
    except FastqParseError as e:
        print(f"FASTQ parse error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
