"""Find the large gaps between chunks."""
from __future__ import annotations

import argparse
from pathlib import Path

import h5py


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("tio", type=Path)
    args = ap.parse_args()

    file_size = args.tio.stat().st_size

    offsets_sizes = []
    with h5py.File(args.tio, "r") as f:
        def collect(name, obj):
            if isinstance(obj, h5py.Dataset):
                try:
                    nc = obj.id.get_num_chunks()
                except Exception:
                    return
                for i in range(nc):
                    info = obj.id.get_chunk_info(i)
                    offsets_sizes.append((info.byte_offset, info.size, name, i))
        f.visititems(collect)

    offsets_sizes.sort(key=lambda t: t[0])
    print(f"File size: {file_size:,}")
    print(f"Total chunks: {len(offsets_sizes):,}")
    print()

    # Find gaps and what's around them.
    gaps = []
    prev_end = 10944  # start of first chunk
    prev_name = "(superblock)"
    prev_idx = -1
    for off, sz, name, i in offsets_sizes:
        if off > prev_end:
            gap = off - prev_end
            gaps.append((gap, prev_end, off, prev_name, prev_idx, name, i))
        prev_end = max(prev_end, off + sz)
        prev_name = name
        prev_idx = i

    # Sort gaps by size descending.
    gaps.sort(key=lambda t: -t[0])
    print(f"Top 20 gaps between chunks (where HDF5 puts metadata):")
    print(f"  {'size':>12}  {'start':>12}  {'end':>12}  {'before':<70} {'after':<70}")
    total = 0
    for gap, gstart, gend, before, b_idx, after, a_idx in gaps[:20]:
        total += gap
        print(f"  {gap:>12,}  {gstart:>12,}  {gend:>12,}  {before}[{b_idx}]"[:84]
              + f" -> {after}[{a_idx}]"[:80])
    print()
    print(f"Sum of all gaps: {sum(g[0] for g in gaps):,} ({sum(g[0] for g in gaps)/file_size*100:.1f}% of file)")
    print(f"Number of gap regions: {len(gaps):,}")
    print(f"Mean gap: {sum(g[0] for g in gaps)/len(gaps):.0f} bytes")
    print(f"Median gap: {sorted([g[0] for g in gaps])[len(gaps)//2]:,} bytes")

if __name__ == "__main__":
    main()
