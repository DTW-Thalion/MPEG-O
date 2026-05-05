"""FASTA import CLI — converts a FASTA file into either an embedded
reference inside a ``.tio`` container or a stand-alone unaligned
genomic run.

Usage
-----
::

    python -m ttio.tools.fasta_import_cli reference \\
        --fasta GRCh38.fa --out study.tio --uri GRCh38

    python -m ttio.tools.fasta_import_cli unaligned \\
        --fasta panel.fa --out study.tio --sample S1

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

from ..importers.fasta import FastaParseError, FastaReader
from ..spectral_dataset import SpectralDataset


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ttio.tools.fasta_import_cli",
        description="Import FASTA into a .tio container.",
    )
    sub = p.add_subparsers(dest="mode", required=True)

    ref = sub.add_parser("reference", help="embed FASTA as a reference genome")
    ref.add_argument("--fasta", required=True, type=Path)
    ref.add_argument("--out", required=True, type=Path)
    ref.add_argument("--uri", default=None,
                     help="reference URI (default: derived from filename)")
    ref.add_argument("--overwrite", action="store_true",
                     help="replace any existing reference at the same URI")

    una = sub.add_parser("unaligned", help="import FASTA as an unaligned run")
    una.add_argument("--fasta", required=True, type=Path)
    una.add_argument("--out", required=True, type=Path)
    una.add_argument("--name", default="genomic_0001",
                     help="genomic-run name under /study/genomic_runs/")
    una.add_argument("--sample", default="", help="sample name")
    una.add_argument("--platform", default="", help="platform tag")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)

    try:
        reader = FastaReader(args.fasta)
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    try:
        if args.mode == "reference":
            ref = reader.read_reference(uri=args.uri)
            # Write a minimal empty container, then re-open writable
            # to embed the reference under /study/references/<uri>/.
            SpectralDataset.write_minimal(
                args.out,
                title="",
                isa_investigation_id="",
                runs={},
            )
            with SpectralDataset.open(args.out, writable=True) as ds:
                ref.write_to_dataset(ds, overwrite=args.overwrite)
            print(
                f"embedded reference {ref.uri!r} "
                f"({len(ref.chromosomes)} chromosomes, "
                f"{ref.total_bases} bases) into {args.out}"
            )
            return 0
        else:
            run = reader.read_unaligned(
                sample_name=args.sample, platform=args.platform
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
                f"({len(run.read_names)} reads) to {args.out}"
            )
            return 0
    except FastaParseError as e:
        print(f"FASTA parse error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
