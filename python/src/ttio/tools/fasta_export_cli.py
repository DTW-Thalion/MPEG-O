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
    """Read an embedded reference genome from a ``.tio`` container.

    Reads through the dataset's :class:`StorageProvider` to access the
    embedded reference under ``/study/references/``.

    Parameters
    ----------
    ds : SpectralDataset
        Opened provider-backed dataset.
    uri : str
        Reference URI under ``/study/references/``.

    Returns
    -------
    ReferenceImport
        The reconstructed reference object.

    Raises
    ------
    RuntimeError
        If the dataset is not provider-backed or has no embedded
        references.
    KeyError
        If no reference is embedded at ``uri``.
    """
    provider = getattr(ds, "provider", None)
    if provider is None:
        raise RuntimeError(
            "fasta_export_cli requires a provider-backed input; "
            f"got {type(ds).__name__} with no .provider."
        )
    root = provider.root_group()
    if not (root.has_child("study")
            and root.open_group("study").has_child("references")):
        raise RuntimeError(
            "fasta_export_cli requires a provider-backed input with "
            f"embedded references; got {type(provider).__name__} with "
            "no /study/references group."
        )
    refs = root.open_group("study").open_group("references")
    if not refs.has_child(uri):
        raise KeyError(f"reference {uri!r} not embedded in input")
    grp = refs.open_group(uri)
    md5_attr = grp.get_attribute("md5")
    if isinstance(md5_attr, bytes):
        md5_hex = md5_attr.decode("ascii")
    else:
        md5_hex = bytes(md5_attr).decode("ascii") if hasattr(md5_attr, "tobytes") \
            else str(md5_attr)
    md5 = bytes.fromhex(md5_hex)
    chrom_grp = grp.open_group("chromosomes")
    names: list[str] = sorted(chrom_grp.child_names())
    seqs: list[bytes] = [
        bytes(np.asarray(chrom_grp.open_group(n).open_dataset("data").read()).tobytes())
        for n in names
    ]
    return ReferenceImport(uri=uri, chromosomes=names, sequences=seqs, md5=md5)


def main(argv: list[str] | None = None) -> int:
    """Emit an embedded reference or a genomic run as a FASTA file.

    Two subcommands are exposed:

    * ``reference`` — write an embedded reference genome to FASTA.
    * ``run`` — write an unaligned genomic run to FASTA.

    Both subcommands emit a samtools-style ``.fai`` index alongside
    the FASTA unless ``--no-fai`` is set.

    Parameters
    ----------
    argv : list[str], optional
        Argument vector. Defaults to ``sys.argv[1:]`` when ``None``.

    Returns
    -------
    int
        ``0`` on success, ``2`` on I/O / lookup failure. Argparse
        exits with ``2`` on usage errors.
    """
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
