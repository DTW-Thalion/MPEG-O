"""Extract qualities + sequences + read_lengths + flags from a BAM
for the qualities-V5 sequence-context bake-off. Reuses BamReader.

Usage:
    .venv/bin/python -m tools.perf.m94z_v4_prototype.extract_seqctx_inputs \
        --bam <path>.bam --out-prefix /tmp/corpus

Produces:
    {prefix}_qual.bin   — flat uint8 quality bytes (raw BAM values)
    {prefix}_seq.bin    — flat uint8 base bytes (ASCII ACGTN), parallel
                          to _qual.bin position-for-position
    {prefix}_lens.bin   — uint32 array of per-read lengths
    {prefix}_flags.bin  — uint32 array of per-read SAM flags

Reads whose SEQ is absent ('*') would break the parallel layout; the
encode-time gate writes those runs as V4, so this extractor asserts
len(sequences) == len(qualities) rather than handling the mixed case.
"""
from __future__ import annotations
import argparse
import sys

import numpy as np

from ttio.importers.bam import BamReader


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bam", required=True)
    ap.add_argument("--out-prefix", required=True)
    args = ap.parse_args()

    run = BamReader(args.bam).to_genomic_run(name="run_0001")
    qualities = np.asarray(run.qualities, dtype=np.uint8)
    sequences = np.asarray(run.sequences, dtype=np.uint8)
    read_lengths = np.asarray([int(x) for x in run.lengths], dtype=np.uint32)
    flags = np.asarray([int(f) for f in run.flags], dtype=np.uint32)

    assert sequences.shape[0] == qualities.shape[0], (
        "SEQ/QUAL length mismatch — corpus has '*'-SEQ reads; "
        "the V5 encode gate excludes these, pick another corpus slice")
    assert int(read_lengths.sum()) == qualities.shape[0]

    qualities.tofile(f"{args.out_prefix}_qual.bin")
    sequences.tofile(f"{args.out_prefix}_seq.bin")
    read_lengths.tofile(f"{args.out_prefix}_lens.bin")
    flags.tofile(f"{args.out_prefix}_flags.bin")
    print(f"qualities: {qualities.shape[0]:,} bytes")
    print(f"sequences: {sequences.shape[0]:,} bytes")
    print(f"reads: {read_lengths.shape[0]:,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
