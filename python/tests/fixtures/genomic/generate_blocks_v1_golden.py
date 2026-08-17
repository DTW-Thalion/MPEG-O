"""Regenerate ``blocks_v1_golden.tio``: the m87 test BAM written through
the streaming BAM importer with ``block_reads=4`` (several blocks, a
mixed-codec unmapped block, an embedded synthetic reference so
REF_DIFF_V2 engages on the mapped blocks).

    python tests/fixtures/genomic/generate_blocks_v1_golden.py

The reference is derived from the BAM itself: for each @SQ contig a
sequence long enough for every read, filled deterministically and
overwritten with the read bases at their positions (M-only CIGARs), so
the fixture is self-contained. Cross-language: Java and ObjC readers
must open this file and match ``samtools view`` of the source BAM on
SAM columns 1-11 (format-spec 10.12).
"""
from __future__ import annotations

import random
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
BAM = HERE / "m87_test.bam"
OUT = HERE / "blocks_v1_golden.tio"
REF = HERE / "blocks_v1_golden_ref.fa"


def _build_reference() -> Path:
    hdr = subprocess.run(["samtools", "view", "-H", str(BAM)], capture_output=True, text=True, check=True).stdout
    lengths = {}
    for line in hdr.splitlines():
        if line.startswith("@SQ"):
            f = dict(x.split(":", 1) for x in line.split("\t")[1:])
            lengths[f["SN"]] = int(f["LN"])
    rng = random.Random(87)
    seqs = {n: bytearray(rng.choice(b"ACGT") for _ in range(min(l, 20_000))) for n, l in lengths.items()}
    body = subprocess.run(["samtools", "view", str(BAM)], capture_output=True, text=True, check=True).stdout
    for line in body.splitlines():
        c = line.split("\t")
        chrom, pos, cigar, seq = c[2], int(c[3]), c[5], c[9]
        if chrom == "*" or seq == "*" or not re.fullmatch(r"\d+M", cigar):
            continue
        s = seqs[chrom]
        s[pos - 1:pos - 1 + len(seq)] = seq.encode()
    REF.write_text("".join(f">{n}\n{bytes(s).decode()}\n" for n, s in seqs.items()))
    subprocess.run(["samtools", "faidx", str(REF)], check=True)
    return REF


def main() -> None:
    from ttio.importers import registry
    ref = _build_reference()
    if OUT.exists():
        OUT.unlink()
    registry.encode("bam", [str(BAM)], str(OUT), reference=str(ref), embed_reference=True,
                    block_reads=4)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
