"""R1 spec-proof bake-off: float-codec candidates for codec id 17.

Corpora: real Orbitrap channels (PXD000001), synthetic NMR FID and
Raman cube (physically motivated, labelled synthetic), index arrays.

Candidates:
  gzip6            pre-#280 default (historical baseline)
  sh+gzip6         CURRENT default on main (post-#280 shuffle)
  sh+zstd19        best generic HDF5-filter stack
  d17-zstd{3,9,19} the proposed codec id 17: u64-view delta ->
                   byte-plane transpose -> zstd (exact, lossless,
                   ~50 lines of C in each language)
  pco / pco12      Pco (pcodec) default + max level: the ceiling
  alp-est          ALP classic/RD size ESTIMATE (no timing; justifies
                   choosing / not choosing an ALP-class design)

Run: .venv/bin/python bench2.py <out_json>
"""
import json
import sys
import time
import zlib

import numpy as np

OUT = sys.argv[1]
CACHE = "/tmp/ttio-comp-bench"
MZML = f"{CACHE}/TMT_Erwinia_1uLSike_Top10HCD_isol2_45stepped_60min_01-20141210.mzML"


# ------------------------------------------------------------- corpora
def load_or_parse_ms():
    import os
    names = ["ms1_mz", "ms1_intensity", "ms2_mz", "ms2_intensity",
             "retention_times"]
    if all(os.path.exists(f"{CACHE}/{n}.npy") for n in names):
        return {n: np.load(f"{CACHE}/{n}.npy") for n in names}
    from pyteomics import mzml as pmzml
    mz1, it1, mz2, it2, rts = [], [], [], [], []
    pts = 0
    rd = pmzml.read(MZML)
    while pts < 30_000_000:
        try:
            s = next(rd)
        except Exception:
            break
        mza = np.asarray(s["m/z array"], dtype=np.float64)
        ita = np.asarray(s["intensity array"], dtype=np.float64)
        if s.get("ms level", 1) == 1:
            mz1.append(mza); it1.append(ita)
        else:
            mz2.append(mza); it2.append(ita)
        try:
            rts.append(float(s["scanList"]["scan"][0]["scan start time"]))
        except Exception:
            rts.append(0.0)
        pts += len(mza)
    out = {
        "ms1_mz": np.concatenate(mz1), "ms1_intensity": np.concatenate(it1),
        "ms2_mz": np.concatenate(mz2), "ms2_intensity": np.concatenate(it2),
        "retention_times": np.asarray(rts, dtype=np.float64),
    }
    for n, a in out.items():
        np.save(f"{CACHE}/{n}.npy", a)
    return out


def synth_fid(n_fids=64, points=65536, seed=7):
    """SYNTHETIC 1-D NMR FID real channel: sum of decaying sinusoids
    + noise, concatenated per the fid_real_values layout."""
    rng = np.random.default_rng(seed)
    t = np.arange(points) / points
    chunks = []
    for _ in range(n_fids):
        k = rng.integers(20, 60)
        f = rng.uniform(5, 8000, k)
        t2 = rng.uniform(0.02, 0.4, k)
        amp = rng.lognormal(0, 1.2, k)
        ph = rng.uniform(0, 2 * np.pi, k)
        sig = (amp[:, None] * np.exp(-t[None, :] / t2[:, None])
               * np.cos(2 * np.pi * f[:, None] * t[None, :] + ph[:, None])).sum(0)
        sig += rng.normal(0, amp.sum() * 2e-4, points)
        chunks.append(sig)
    return np.concatenate(chunks)


def synth_raman_cube(h=96, w=96, sp=1024, seed=11):
    """SYNTHETIC Raman cube: smooth spatial fields modulating fixed
    Lorentzian peaks + polynomial baseline + shot-ish noise. Flat in
    (H, W, SP) storage order."""
    rng = np.random.default_rng(seed)
    x = np.linspace(0, 1, sp)
    peaks = rng.uniform(0.05, 0.95, 8)
    widths = rng.uniform(0.002, 0.01, 8)
    yy, xx = np.mgrid[0:h, 0:w] / max(h, w)
    fields = [
        (np.sin(3 * np.pi * (yy * rng.uniform(0.5, 2) + xx * rng.uniform(0.5, 2)
                             + rng.uniform(0, 1))) + 1.2) * rng.uniform(50, 400)
        for _ in range(8)
    ]
    base = 100 + 80 * x - 60 * x**2
    lor = [1.0 / (1.0 + ((x - p) / wd) ** 2) for p, wd in zip(peaks, widths)]
    cube = np.empty((h, w, sp))
    for i in range(h):
        row = base[None, :] + sum(
            fields[k][i][:, None] * lor[k][None, :] for k in range(8))
        cube[i] = row + rng.normal(0, np.sqrt(np.maximum(row, 1)) * 0.3)
    return cube.ravel()


# ---------------------------------------------------------- candidates
def t_run(fn, *args):
    t0 = time.perf_counter()
    r = fn(*args)
    return r, time.perf_counter() - t0


def shuffle_bytes(arr):
    b = arr.view(np.uint8).reshape(-1, arr.dtype.itemsize)
    return np.ascontiguousarray(b.T).tobytes()


def unshuffle_bytes(buf, dtype, n):
    b = np.frombuffer(buf, dtype=np.uint8).reshape(dtype.itemsize, n)
    return np.ascontiguousarray(b.T).reshape(-1).view(dtype)


def u64_delta(arr):
    u = arr.view(np.uint64)
    d = np.empty_like(u)
    d[0] = u[0]
    np.subtract(u[1:], u[:-1], out=d[1:])
    return d


def u64_undelta(d):
    return np.cumsum(d, dtype=np.uint64)


def cand_d17(arr, level):
    """Proposed codec id 17: u64 delta -> byte-plane transpose -> zstd."""
    import zstandard
    d = u64_delta(arr)
    planes = shuffle_bytes(d)
    c = zstandard.ZstdCompressor(level=level).compress(planes)
    return c


def cand_d17_decode(c, n):
    import zstandard
    planes = zstandard.ZstdDecompressor().decompress(c, max_output_size=n * 8)
    d = unshuffle_bytes(planes, np.dtype(np.uint64), n)
    return u64_undelta(d).view(np.float64)


def alp_estimate(arr, vec=1024):
    """Size estimate for an ALP-class codec (classic decimal path with
    per-vector exponent + exceptions; ALP-RD fallback). Estimate only."""
    n = len(arr)
    pad = (-n) % vec
    v = np.concatenate([arr, np.zeros(pad)]) if pad else arr
    nv = len(v) // vec
    vm = v.reshape(nv, vec)
    best = np.full(nv, np.inf)
    for s in range(15):
        scale = 10.0 ** s
        ints = np.round(vm * scale)
        ok = (ints * (10.0 ** -s)) == vm
        with np.errstate(invalid="ignore"):
            imin = np.where(ok, ints, np.inf).min(axis=1)
            imax = np.where(ok, ints, -np.inf).max(axis=1)
        rng_ = np.maximum(imax - imin, 1)
        bits = np.ceil(np.log2(rng_ + 1))
        exc = (~ok).sum(axis=1)
        # FFOR bits + 10 B per exception + 16 B vector header.
        size = vec * bits / 8 + exc * 10 + 16
        # A vector with >50% exceptions is not a classic-path vector.
        size = np.where(exc > vec // 2, np.inf, size)
        best = np.minimum(best, size)
    # ALP-RD fallback for vectors classic can't take: left-16-bit dict
    # + raw 48 right bits (the paper's shape).
    u = vm.view(np.uint64) >> 48
    rd_bits = np.empty(nv)
    for i in range(nv):
        d = len(np.unique(u[i]))
        rd_bits[i] = 48 + max(1, np.ceil(np.log2(max(d, 2))))
    rd_size = vec * rd_bits / 8 + 64
    est = np.minimum(best, rd_size).sum()
    return int(est * (n / len(v)))


def bench_channel(name, arr, results):
    import zstandard
    raw = arr.nbytes
    n = len(arr)
    rows = {}
    print(f"\n=== {name}: {n:,} f64 = {raw/1e6:.1f} MB ===", flush=True)

    def add(label, size, enc_s=None, dec_s=None):
        rows[label] = dict(bytes=int(size), ratio=raw / size,
                           enc_s=None if enc_s is None else round(enc_s, 2),
                           dec_s=None if dec_s is None else round(dec_s, 2))
        e = "" if enc_s is None else f"  enc {enc_s:6.2f}s"
        d = "" if dec_s is None else f" dec {dec_s:5.2f}s"
        print(f"  {label:16s} {size/1e6:9.2f} MB  x{raw/size:5.2f}{e}{d}",
              flush=True)

    c, te = t_run(zlib.compress, arr.tobytes(), 6)
    add("gzip6", len(c), te)

    sh, tsh = t_run(shuffle_bytes, arr)
    c, te = t_run(zlib.compress, sh, 6)
    add("sh+gzip6 (cur)", len(c), te + tsh)

    c, te = t_run(zstandard.ZstdCompressor(level=19).compress, sh)
    add("sh+zstd19", len(c), te + tsh)

    for lvl in (3, 9, 19):
        c, te = t_run(cand_d17, arr, lvl)
        back, td = t_run(cand_d17_decode, c, n)
        assert np.array_equal(back.view(np.uint64), arr.view(np.uint64))
        add(f"d17-zstd{lvl}", len(c), te, td)

    from pcodec import standalone, ChunkConfig
    c, te = t_run(standalone.simple_compress, arr, ChunkConfig())
    back, td = t_run(standalone.simple_decompress, c)
    assert np.array_equal(back.view(np.uint64), arr.view(np.uint64))
    add("pco", len(c), te, td)

    c, te = t_run(standalone.simple_compress, arr,
                  ChunkConfig(compression_level=12))
    add("pco12", len(c), te)

    est, te = t_run(alp_estimate, arr)
    add("alp-est", est, te)

    results[name] = dict(raw_bytes=raw, n=n, pipelines=rows)


def main():
    results = {}
    print("loading corpora...", flush=True)
    ms = load_or_parse_ms()
    corpora = dict(ms)
    corpora["nmr_fid (synth)"] = synth_fid()
    corpora["raman_cube (synth)"] = synth_raman_cube()
    for name, arr in corpora.items():
        bench_channel(name, np.ascontiguousarray(arr, dtype=np.float64),
                      results)
    with open(OUT, "w") as f:
        json.dump(results, f, indent=1)
    print(f"\nwrote {OUT}", flush=True)


if __name__ == "__main__":
    main()
