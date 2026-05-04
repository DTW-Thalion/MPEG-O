"""Run NAME_TOKENIZED v2 Phase 0 prototype on real corpora; validate the gate."""
from __future__ import annotations

import os
import subprocess
import sys
import time

from .encode import encode
from .decode import decode

CORPORA = {
    "chr22": "/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam",
    "wes": "/home/toddw/TTI-O/data/genomic/na12878_wes/na12878_wes.chr22.bam",
    "hg002_illumina": "/home/toddw/TTI-O/data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam",
    "hg002_pacbio": "/home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam",
}


def extract_names(bam_path: str, max_reads: int | None = None) -> list[str]:
    """Use samtools view to extract QNAMEs."""
    cmd = ["samtools", "view", bam_path]
    proc = subprocess.run(cmd, capture_output=True, check=True, text=False)
    names: list[str] = []
    star_count = 0
    for line in proc.stdout.split(b"\n"):
        if not line:
            continue
        qname = line.split(b"\t", 1)[0].decode("ascii", errors="replace")
        if qname == "*":
            star_count += 1
            continue
        names.append(qname)
        if max_reads is not None and len(names) >= max_reads:
            break
    if star_count > 0 and len(names) == 0:
        return []  # all star — skip
    return names


def measure_v1(names: list[str]) -> int:
    sys.path.insert(0, "/home/toddw/TTI-O/python/src")
    from ttio.codecs.name_tokenizer import encode as v1_encode  # type: ignore
    return len(v1_encode(names))


def measure_v2(names: list[str], pool_size: int, block_size: int) -> int:
    return len(encode(names, pool_size=pool_size, block_size=block_size))


def main() -> int:
    print(f"{'Corpus':<20} | {'n_reads':>8} | {'v1':>10} | {'v2 (8/4096)':>11} | {'savings':>10} | {'Δ %':>6}")
    print("-" * 88)
    chr22_savings = 0
    for name, path in CORPORA.items():
        if not os.path.exists(path):
            print(f"{name:<20} | {'SKIP':>8} | (BAM not found at {path})")
            continue
        all_names = extract_names(path)
        if not all_names:
            print(f"{name:<20} | {'SKIP':>8} | (BAM has * QNAMEs only)")
            continue
        n = len(all_names)
        v1 = measure_v1(all_names)
        v2_default = measure_v2(all_names, 8, 4096)
        savings = v1 - v2_default
        pct = 100.0 * savings / v1 if v1 > 0 else 0
        print(f"{name:<20} | {n:>8d} | {v1:>10,} | {v2_default:>11,} | {savings:>+10,} | {pct:>5.1f}%")
        if name == "chr22":
            chr22_savings = savings

    # Sweep on chr22
    if os.path.exists(CORPORA["chr22"]):
        print()
        print("chr22 sweep (all numbers in MB):")
        chr22_names = extract_names(CORPORA["chr22"])
        v1_size = measure_v1(chr22_names)
        print(f"  v1 baseline: {v1_size / 1024 / 1024:.3f} MB")
        print()
        print(f"  {'Pool N':>7} \\ {'Block B':<7}  | {1024:>9} | {4096:>9} | {16384:>9}")
        for N in [4, 8, 16, 32]:
            row = [f"  {N:>7}            "]
            for B in [1024, 4096, 16384]:
                sz = measure_v2(chr22_names, N, B)
                row.append(f"{sz/1024/1024:>9.3f}")
            print(" | ".join(row))

    print()
    print(f"=== Phase 0 GATE ===")
    if os.path.exists(CORPORA["chr22"]):
        chr22_names = extract_names(CORPORA["chr22"])
        v1 = measure_v1(chr22_names)
        v2 = measure_v2(chr22_names, 8, 4096)
        savings = v1 - v2
        print(f"chr22 savings = {savings:,} bytes ({savings/1024/1024:.3f} MB)")
        if savings >= 3_000_000:
            print(f"PASS — savings ≥ 3 MB hard gate")
            return 0
        else:
            print(f"FAIL — savings < 3 MB hard gate; design must be revised")
            return 1
    else:
        print("chr22 BAM not found; cannot validate gate")
        return 2


if __name__ == "__main__":
    sys.exit(main())
