# Float-codec bake-off — R1 spec-proof measurements

- Date: 2026-08-16
- Status: codec 17 shipped (Phase 1) and is the default for MS
  float64 channels (Phase 2; `opt_disable_float_delta` opts out).
  The numbers below are the measurements that drove both decisions.
- Spec: `docs/superpowers/specs/2026-08-16-float-delta-codec-design.md`
  (§3 carries the results table and its reading; not duplicated here)
- Scripts: `tools/perf/float_codec_bakeoff/`
- Corpus: PXD000001 mzML (public, ~450 MB download), first 30M points;
  synthetic NMR FID and Raman cube generated in-script with fixed seeds.

## Reproducing

```bash
mkdir -p /tmp/ttio-comp-bench && cd /tmp/ttio-comp-bench
curl -fsSLO https://ftp.pride.ebi.ac.uk/pride/data/archive/2012/03/PXD000001/TMT_Erwinia_1uLSike_Top10HCD_isol2_45stepped_60min_01-20141210.mzML

cd <repo>
.venv/bin/pip install pcodec zstandard   # bench-only deps
.venv/bin/python tools/perf/float_codec_bakeoff/bench.py /tmp/ttio-comp-bench/bakeoff.json
.venv/bin/python tools/perf/float_codec_bakeoff/bench_rans_floors.py /tmp/ttio-comp-bench/rans-floors.json
.venv/bin/python tools/perf/float_codec_bakeoff/bench_t0_levels.py
```

Every lossless row is verified bit-exact on round-trip inside the
scripts. `alp-est` rows are size estimates (classic decimal path with
per-vector exponent + exceptions, ALP-RD fallback), labelled as such;
`ransO0/O1-floor` rows are information-theoretic floors, not codec
output.

## Conclusions (details in the spec)

1. Transform first: delta/none on the u64 view + byte-plane
   transpose is where the win is; plain codec swaps do near nothing
   on profile m/z.
2. Whole-stream beats the per-chunk HDF5 filter pipeline by ~37% on
   the same shuffle+zstd stack.
3. ALP-class is eliminated on data (x1.28 on profile m/z — no delta
   stage, classic path drowns in exceptions on non-decimal values).
4. In-house rANS-O1 floors ~28% above zstd on the transposed delta
   stream — the one place the ids-4-15 entropy pattern is
   measurably insufficient.
5. The proposed FLOAT_DELTA_ZSTD matches Pco within 1% at level 19
   and within 12% at the level-9 default across the four MS
   channels, at ~100 MB/s encode / ~580 MB/s decode.
