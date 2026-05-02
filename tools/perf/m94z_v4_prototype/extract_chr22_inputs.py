"""Extract qualities + read_lengths + flags from a BAM into binary
files for the C-side byte-equality tests. Reuses BamReader.

Usage:
    .venv/bin/python -m tools.perf.m94z_v4_prototype.extract_chr22_inputs \
        --bam /home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam \
        --out-prefix /tmp/chr22

Produces:
    {prefix}_qual.bin   — flat uint8 quality bytes (Phred+0, NOT ASCII; raw BAM values)
    {prefix}_lens.bin   — uint32 array of per-read quality lengths
    {prefix}_flags.bin  — uint32 array of per-read SAM flags

Note on flags: htscodecs `fqz_slice.flags` is `uint32_t *`, so we emit
uint32 here. For Phase 2 strategy 1 with do_sel=do_r2=do_dedup=0 and
gflags=0, the flag stream is unused by both encoders — but we keep the
full uint32 width for forward-compat with Phase 3.
"""
from __future__ import annotations
import argparse
import sys

import numpy as np

from ttio.importers.bam import BamReader


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bam", required=True)
    ap.add_argument("--out-prefix", required=True,
                    help="e.g. /tmp/chr22 -> produces _qual.bin, _lens.bin, _flags.bin")
    args = ap.parse_args()

    run = BamReader(args.bam).to_genomic_run(name="run_0001")
    qualities = bytes(run.qualities.tobytes())
    read_lengths = np.asarray([int(x) for x in run.lengths], dtype=np.uint32)
    flags = np.asarray([int(f) for f in run.flags], dtype=np.uint32)

    with open(f"{args.out_prefix}_qual.bin", "wb") as f:
        f.write(qualities)
    read_lengths.tofile(f"{args.out_prefix}_lens.bin")
    flags.tofile(f"{args.out_prefix}_flags.bin")
    print(f"qualities: {len(qualities):,} bytes")
    print(f"reads: {read_lengths.shape[0]:,}")
    print(f"flags: {flags.shape[0]:,} (uint32)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
