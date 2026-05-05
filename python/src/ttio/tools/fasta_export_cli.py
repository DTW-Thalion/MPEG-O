"""FASTA export CLI — emits an embedded reference or a genomic run
to a FASTA file.

Usage
-----
::

    python -m ttio.tools.fasta_export_cli reference \\
        --in study.tio --uri GRCh38 --out GRCh38.fa --line-width 60

    python -m ttio.tools.fasta_export_cli run \\
        --in study.tio --name genomic_0001 --out reads.fa

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

import numpy as np

from ..exporters.fasta import DEFAULT_LINE_WIDTH, FastaWriter
from ..genomic.reference_import import ReferenceImport
from ..spectral_dataset import SpectralDataset


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ttio.tools.fasta_export_cli",
        description="Export FASTA from a .tio container.",
    )
    sub = p.add_subparsers(dest="mode", required=True)

    ref = sub.add_parser("reference", help="export an embedded reference")
    ref.add_argument("--in", dest="in_path", required=True, type=Path)
    ref.add_argument("--uri", required=True, help="reference URI to export")
    ref.add_argument("--out", required=True, type=Path)
    ref.add_argument("--line-width", type=int, default=DEFAULT_LINE_WIDTH)
    ref.add_argument("--no-fai", action="store_true",
                     help="skip emitting a samtools-style .fai index")

    run = sub.add_parser("run", help="export an unaligned genomic run")
    run.add_argument("--in", dest="in_path", required=True, type=Path)
    run.add_argument("--name", required=True,
                     help="genomic-run name under /study/genomic_runs/")
    run.add_argument("--out", required=True, type=Path)
    run.add_argument("--line-width", type=int, default=DEFAULT_LINE_WIDTH)
    run.add_argument("--no-fai", action="store_true")
    return p


def _load_embedded_reference(ds: SpectralDataset, uri: str) -> ReferenceImport:
    h5 = ds.file
    if h5 is None:
        raise RuntimeError(
            "fasta_export_cli requires an HDF5-backed input; "
            f"got {type(ds).__name__} with no .file handle."
        )
    grp = h5.get(f"/study/references/{uri}")
    if grp is None:
        raise KeyError(f"reference {uri!r} not embedded in input")
    md5_attr = grp.attrs["md5"]
    if isinstance(md5_attr, bytes):
        md5_hex = md5_attr.decode("ascii")
    else:
        md5_hex = bytes(md5_attr).decode("ascii") if hasattr(md5_attr, "tobytes") \
            else str(md5_attr)
    md5 = bytes.fromhex(md5_hex)
    chrom_grp = grp["chromosomes"]
    names: list[str] = sorted(chrom_grp.keys())
    seqs: list[bytes] = [
        bytes(np.asarray(chrom_grp[n]["data"]).tobytes()) for n in names
    ]
    return ReferenceImport(uri=uri, chromosomes=names, sequences=seqs, md5=md5)


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    write_fai = not args.no_fai

    try:
        with SpectralDataset.open(args.in_path) as ds:
            if args.mode == "reference":
                ref = _load_embedded_reference(ds, args.uri)
                FastaWriter.write_reference(
                    ref, args.out,
                    line_width=args.line_width, write_fai=write_fai,
                )
                print(
                    f"wrote {ref.uri!r} ({len(ref.chromosomes)} chromosomes,"
                    f" {ref.total_bases} bases) to {args.out}"
                )
                return 0
            else:
                run = ds.genomic_runs[args.name]
                n_reads = len(run)
                FastaWriter.write_run(
                    run, args.out,
                    line_width=args.line_width, write_fai=write_fai,
                )
                print(
                    f"wrote run {args.name!r} ({n_reads} reads) "
                    f"to {args.out}"
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
