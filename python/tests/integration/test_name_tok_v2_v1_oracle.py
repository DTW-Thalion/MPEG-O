"""v1↔v2 oracle: chr22 baseline measurement + round-trip on real data."""
from __future__ import annotations

import os
import subprocess
import pytest

from ttio.codecs import name_tokenizer as nt1
from ttio.codecs import name_tokenizer_v2 as nt2

CHR22_BAM = "/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam"


@pytest.mark.integration
def test_chr22_v2_round_trip_and_baseline(capsys):
    if not nt2.HAVE_NATIVE_LIB:
        pytest.skip("native lib not loaded")
    if not os.path.exists(CHR22_BAM):
        pytest.skip(f"BAM not found: {CHR22_BAM}")

    proc = subprocess.run(
        ["samtools", "view", CHR22_BAM],
        capture_output=True, check=True,
    )
    names: list[str] = []
    for line in proc.stdout.split(b"\n"):
        if not line:
            continue
        qname = line.split(b"\t", 1)[0].decode("ascii")
        names.append(qname)

    v1_blob = nt1.encode(names)
    v2_blob = nt2.encode(names)

    decoded = nt2.decode(v2_blob)
    assert decoded == names, "v2 round-trip failed"

    v1_size = len(v1_blob)
    v2_size = len(v2_blob)
    savings = v1_size - v2_size
    with capsys.disabled():
        print()
        print(f"chr22 read_names sizes (n_names={len(names):,}):")
        print(f"  v1 NAME_TOKENIZED:    {v1_size:>10,} bytes ({v1_size / 1024 / 1024:.3f} MB)")
        print(f"  v2 NAME_TOKENIZED_V2: {v2_size:>10,} bytes ({v2_size / 1024 / 1024:.3f} MB)")
        print(f"  Savings:               {savings:>10,} bytes ({savings / 1024 / 1024:.3f} MB)")
        print(f"  Reduction:             {100 * savings / v1_size:>9.1f}%")

    # Soft floor: 2.5 MB at this stage. Phase 0 prototype hit 5.71 MB.
    # Production rANS-O0 should match or beat the zlib-proxy result.
    # Task 15 enforces the 3 MB hard gate at the dataset level.
    assert savings >= 2_500_000, f"v2 savings {savings} below floor — expected ≥ 2.5 MB"
