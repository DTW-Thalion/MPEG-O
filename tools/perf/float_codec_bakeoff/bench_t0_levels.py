"""T0 (no-delta) + transpose + zstd at levels 3/9 for the two
intensity channels — completes the per-block-selector story at the
default level."""
import sys
import time

import numpy as np
import zstandard

CACHE = "/tmp/ttio-comp-bench"

for name in ("ms1_intensity", "ms2_intensity", "ms1_mz", "ms2_mz"):
    arr = np.load(f"{CACHE}/{name}.npy")
    raw = arr.nbytes
    b = arr.view(np.uint8).reshape(-1, 8)
    planes = np.ascontiguousarray(b.T).tobytes()
    for lvl in (3, 9):
        t0 = time.perf_counter()
        c = zstandard.ZstdCompressor(level=lvl).compress(planes)
        dt = time.perf_counter() - t0
        print(f"  {name} T0+zstd{lvl}: {len(c)/1e6:8.2f} MB "
              f"x{raw/len(c):5.2f}  enc {dt:6.2f}s", flush=True)
