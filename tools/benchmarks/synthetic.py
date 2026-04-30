"""Generate the synthetic mixed-chromosome benchmark dataset.

Produces a deterministic BAM file with reads spread across every
GRCh38 chromosome (including chrM and the small contigs) plus a
matching minimal-sufficient reference FASTA. The output is the
fixture referenced by ``DATASETS["synthetic_mixed_chrom"]``.

Run::

    python -m tools.benchmarks.synthetic \\
        --out data/genomic/synthetic/mixed_chrom.bam \\
        --reads-per-chrom 2000 \\
        --seed 0xBEEF
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable


def _require(binary: str) -> str:
    path = shutil.which(binary)
    if path is None:
        raise SystemExit(f"error: {binary} not on PATH")
    return path


GRCH38_CHROMS: list[tuple[str, int]] = [
    # Subset chosen to keep synthetic generation tractable while
    # still touching every chromosome class (autosomal large/small,
    # sex, mitochondrial). Real lengths approximated to within 1%.
    ("chr1",   248_956_422),
    ("chr10",  133_797_422),
    ("chr19",   58_617_616),
    ("chr21",   46_709_983),
    ("chr22",   50_818_468),
    ("chrX",   156_040_895),
    ("chrY",    57_227_415),
    ("chrM",       16_569),
]


def _chrom_seq(name: str, length: int, seed: int) -> bytes:
    import random
    rng = random.Random(seed ^ hash(name))
    return bytes(rng.choice(b"ACGT") for _ in range(length))


def _emit_sam_header(chroms: Iterable[tuple[str, int]]) -> str:
    lines = ["@HD\tVN:1.6\tSO:coordinate"]
    for name, length in chroms:
        lines.append(f"@SQ\tSN:{name}\tLN:{length}")
    lines.append("@RG\tID:bench\tSM:synthetic\tPL:ILLUMINA")
    lines.append("@PG\tID:tools.benchmarks.synthetic\tPN:ttio-synth\tVN:1")
    return "\n".join(lines) + "\n"


def _emit_reads(chroms, reads_per_chrom: int, seed: int) -> Iterable[str]:
    import random
    rng = random.Random(seed)
    qual = "I" * 100  # Phred 40
    for name, length in chroms:
        for i in range(reads_per_chrom):
            pos = 1 + rng.randrange(0, max(1, length - 100))
            seq = "".join(rng.choices("ACGT", k=100))
            yield (
                f"r{name}_{i}\t0\t{name}\t{pos}\t60\t100M\t*\t0\t0\t{seq}\t{qual}\tRG:Z:bench\n"
            )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--reads-per-chrom", type=int, default=2000)
    p.add_argument(
        "--seed", type=lambda s: int(s, 0), default=0xBEEF,
        help="integer (decimal or 0x-prefixed hex)",
    )
    p.add_argument(
        "--reference-out", type=Path, default=None,
        help="if given, also emit a minimal FASTA next to the BAM",
    )
    args = p.parse_args(argv)

    samtools = _require("samtools")
    args.out.parent.mkdir(parents=True, exist_ok=True)

    sam_path = args.out.with_suffix(".sam")
    with sam_path.open("w") as fh:
        fh.write(_emit_sam_header(GRCH38_CHROMS))
        for line in _emit_reads(GRCH38_CHROMS, args.reads_per_chrom, args.seed):
            fh.write(line)

    subprocess.check_call(
        [samtools, "view", "-b", "-o", str(args.out), str(sam_path)]
    )
    sam_path.unlink()

    if args.reference_out is not None:
        args.reference_out.parent.mkdir(parents=True, exist_ok=True)
        with args.reference_out.open("w") as fh:
            for name, length in GRCH38_CHROMS:
                fh.write(f">{name}\n")
                seq = _chrom_seq(name, length, args.seed)
                # 80 chars per line per FASTA convention.
                for i in range(0, len(seq), 80):
                    fh.write(seq[i:i + 80].decode("ascii") + "\n")
        subprocess.check_call([samtools, "faidx", str(args.reference_out)])

    print(f"wrote {args.out}", file=sys.stderr)
    if args.reference_out is not None:
        print(f"wrote {args.reference_out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
