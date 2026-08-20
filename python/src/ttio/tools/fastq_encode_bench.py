"""FASTQ encode benchmark.

Usage
-----
::

    python -m ttio.tools.fastq_encode_bench in.fastq[.gz] out.tio \\
        [batch_bytes [block_bytes]]

``batch_bytes`` 0 (or omitted) means the 64 MiB default. Prints one
``[py-bench]`` line so the number can be watched over time; the
regression-tracking twin of ``TtioFastqEncodeBench`` (ObjC) and
``FastqEncodeBench`` (Java).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

from .._threads import resolve_threads
from ..importers.fastq import FastqReader
from ..spectral_dataset import SpectralDataset


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not 2 <= len(argv) <= 4:
        print("usage: fastq_encode_bench in out [batch_bytes [block_bytes]]",
              file=sys.stderr)
        return 1
    src_path, out = Path(argv[0]), Path(argv[1])
    batch_bytes = int(argv[2]) if len(argv) > 2 else 0
    block_bytes = int(argv[3]) if len(argv) > 3 else None
    kw = {"batch_bytes": batch_bytes} if batch_bytes > 0 else {}
    threads = resolve_threads(None)
    t0 = time.monotonic()
    source = FastqReader(src_path).stream_source(sample_name="s", **kw)
    if block_bytes is not None:
        source.block_bytes = block_bytes
    SpectralDataset.write_minimal(out, title="", isa_investigation_id="",
                                  runs={})
    with SpectralDataset.open(out, writable=True) as ds:
        n = source.write_into(ds.study_group)
    dt = time.monotonic() - t0
    in_bytes = src_path.stat().st_size
    print(f"[py-bench] reads={n} threads={threads} seconds={dt:.1f} "
          f"mb_per_s={in_bytes / dt / 1e6:.1f} "
          f"out_bytes={out.stat().st_size}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
