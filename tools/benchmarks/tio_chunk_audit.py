"""Per-dataset chunk audit — count chunks, payload, overhead estimate."""
from __future__ import annotations

import argparse
from pathlib import Path

import h5py
import math


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("tio", type=Path)
    args = ap.parse_args()

    rows = []  # (path, n_elem, chunk_size, n_chunks, storage, dtype_bytes)

    def visit(name, obj):
        if isinstance(obj, h5py.Dataset):
            n_elem = int(obj.size) if obj.size else 0
            chunks = obj.chunks
            storage = obj.id.get_storage_size()
            dt_bytes = obj.dtype.itemsize
            if chunks is None:
                n_chunks = 1
                cs = n_elem
            else:
                cs = 1
                for c in chunks:
                    cs *= c
                # number of chunks = ceil(shape[i]/chunks[i]) per axis, product
                n_chunks = 1
                for s, c in zip(obj.shape, chunks):
                    n_chunks *= math.ceil(s / c) if c > 0 else 1
            rows.append((name, n_elem, cs, n_chunks, storage, dt_bytes,
                         chunks, obj.shape, obj.dtype))

    with h5py.File(args.tio, "r") as f:
        f.visititems(visit)

    # Sort by storage descending.
    rows.sort(key=lambda r: -r[4])

    print(f"{'Path':<70} {'shape':<20} {'chunk':<15} {'#chk':>6} "
          f"{'storage':>12} {'B/chunk':>10}")
    total_storage = 0
    total_chunks = 0
    for path, n, cs, nc, storage, dtb, chunks, shape, dt in rows:
        chunks_str = str(chunks) if chunks else "contig"
        b_per_chunk = storage / nc if nc > 0 else 0
        total_storage += storage
        total_chunks += nc
        print(f"{path:<70} {str(shape):<20} {chunks_str:<15} {nc:>6} "
              f"{storage:>12,} {b_per_chunk:>10.0f}")

    print()
    print(f"Total datasets:  {len(rows)}")
    print(f"Total chunks:    {total_chunks:,}")
    print(f"Total storage:   {total_storage:,} bytes ({total_storage/1e6:.2f} MB)")
    # Rough overhead estimate: HDF5 chunk index B-tree is ~96 bytes per
    # chunk reference at the leaf level (varies by indexing strategy).
    estimated_chunk_overhead = total_chunks * 96
    print(f"Est chunk-tree overhead at 96 B/chunk: "
          f"{estimated_chunk_overhead:,} ({estimated_chunk_overhead/1e6:.2f} MB)")


if __name__ == "__main__":
    main()
