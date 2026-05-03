"""Generate /tmp/py_{name}_v4.fqz reference files from Python's V4 encoder.

Used by Stage 3 cross-language byte-equality tests (Java + ObjC).

Reads the binary inputs already at /tmp (produced by htscodecs_compare.sh),
encodes via fqzcomp_nx16_z.encode(prefer_v4=True), writes M94Z V4 streams.

Usage:
    TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \\
        .venv/bin/python -m tools.perf.m94z_v4_prototype.run_v4_python_references
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

from ttio.codecs.fqzcomp_nx16_z import encode, _HAVE_NATIVE_LIB

CORPORA = ["chr22", "wes", "hg002_illumina", "hg002_pacbio"]
SAM_REVERSE_FLAG = 16


def main() -> int:
    if not _HAVE_NATIVE_LIB:
        print("ERROR: _HAVE_NATIVE_LIB is False; set TTIO_RANS_LIB_PATH", file=sys.stderr)
        return 1

    fails = 0
    for name in CORPORA:
        qual_path = Path(f"/tmp/{name}_v4_qual.bin")
        lens_path = Path(f"/tmp/{name}_v4_lens.bin")
        flags_path = Path(f"/tmp/{name}_v4_flags.bin")
        if not qual_path.exists():
            print(f"SKIP {name}: input files missing (run htscodecs_compare.sh)")
            continue

        qualities = qual_path.read_bytes()
        lens = np.fromfile(lens_path, dtype=np.uint32).tolist()
        flags = np.fromfile(flags_path, dtype=np.uint32)
        revcomp = [(int(f) & SAM_REVERSE_FLAG) != 0 and 1 or 0 for f in flags]

        out = encode(qualities, lens, revcomp, prefer_v4=True)

        out_path = Path(f"/tmp/py_{name}_v4.fqz")
        out_path.write_bytes(out)
        print(f"OK {name}: {len(qualities):,} qualities -> {len(out):,} bytes "
              f"(magic={out[:4]!r}, version={out[4]})")

    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
