"""Supplement: can the in-house rANS replace zstd as d17's entropy
stage? Shannon-entropy (order-0) and conditional-entropy (order-1)
estimates per byte plane of the delta-transposed stream, plus the
same for plain shuffle (no delta). Estimates are information-theoretic
floors for rANS-O0/O1 with per-plane tables; the shipped rANS gets
within a few percent of these on skewed byte streams.

Run: .venv/bin/python bench3.py <out_json>
"""
import json
import sys

import numpy as np

OUT = sys.argv[1]
CACHE = "/tmp/ttio-comp-bench"


def u64_delta(arr):
    u = arr.view(np.uint64)
    d = np.empty_like(u)
    d[0] = u[0]
    np.subtract(u[1:], u[:-1], out=d[1:])
    return d


def planes_of(x):
    return x.view(np.uint8).reshape(-1, 8).T


def h0_bytes(plane):
    c = np.bincount(plane, minlength=256).astype(np.float64)
    p = c[c > 0] / len(plane)
    return -(p * np.log2(p)).sum() * len(plane) / 8


def h1_bytes(plane):
    # Conditional entropy H(X_i | X_{i-1}) over the plane.
    prev = plane[:-1].astype(np.uint16)
    cur = plane[1:].astype(np.uint16)
    joint = np.bincount(prev * 256 + cur, minlength=65536).astype(np.float64)
    joint = joint.reshape(256, 256)
    row = joint.sum(axis=1)
    nz = joint > 0
    with np.errstate(divide="ignore", invalid="ignore"):
        cond = joint / row[:, None]
    h = -(joint[nz] * np.log2(cond[nz])).sum() / joint.sum()
    return h * len(plane) / 8


def main():
    import glob
    import os
    results = {}
    names = ["ms1_mz", "ms1_intensity", "ms2_mz", "ms2_intensity"]
    for name in names:
        arr = np.load(f"{CACHE}/{name}.npy")
        raw = arr.nbytes
        d = u64_delta(arr)
        rows = {}
        for label, x in (("delta", d), ("nodelta", arr.view(np.uint64))):
            pl = planes_of(x)
            o0 = sum(h0_bytes(np.ascontiguousarray(p)) for p in pl)
            o1 = sum(h1_bytes(np.ascontiguousarray(p)) for p in pl)
            rows[f"{label}+transpose+ransO0-floor"] = dict(
                bytes=int(o0), ratio=raw / o0)
            rows[f"{label}+transpose+ransO1-floor"] = dict(
                bytes=int(o1), ratio=raw / o1)
            print(f"  {name} {label}: O0 {o0/1e6:8.2f} MB x{raw/o0:5.2f} | "
                  f"O1 {o1/1e6:8.2f} MB x{raw/o1:5.2f}", flush=True)
        results[name] = dict(raw_bytes=raw, pipelines=rows)
    with open(OUT, "w") as f:
        json.dump(results, f, indent=1)
    print(f"wrote {OUT}", flush=True)


if __name__ == "__main__":
    main()
