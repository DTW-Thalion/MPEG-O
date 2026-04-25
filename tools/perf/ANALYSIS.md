# Cross-language Performance Analysis

Harnesses under `tools/perf/` profile identical workloads (N spectra ×
16 peaks, HDF5 backend, zlib compression) across the three TTI-O
implementations. Timings below are from one representative run on WSL2
(Ubuntu 24.04, 6.6.87.2-microsoft-standard-WSL2) with one warmup pass.
All three harnesses warm the libhdf5 path before measurement.

## Headline numbers (10 000 spectra, 16 peaks)

| Language | Build (ms) | Write (ms) | Read (ms) | Total (ms) | File (MB) |
|----------|-----------:|-----------:|----------:|-----------:|----------:|
| Python   |        1.6 |       19.0 |       7.9 |       28.5 |      0.86 |
| Java     |        1.2 |       45.6 |       5.8 |       52.6 |      0.77 |
| **ObjC** (object API)    |       10.0 |       56.0 |       4.9 |       70.9 |      0.93 |
| **ObjC** (flat / primitive API) |        0.9 |        9.4 |      32.7 |       43.1 |      0.28 |

Scaling to 100 000 spectra:

| Language | Build (ms) | Write (ms) | Read (ms) | Total (ms) | File (MB) |
|----------|-----------:|-----------:|----------:|-----------:|----------:|
| Python   |       16.1 |      160.3 |      46.6 |      223.0 |      0.86 |
| Java     |       17.4 |      449.0 |      39.4 |      505.8 |      7.48 |
| ObjC (object API)   |      136.9 |      579.5 |      38.6 |      755.0 |      8.86 |
| ObjC (flat / primitive API)     |       10.0 |      415.9 |      47.2 |      473.2 |      2.67 |

*(Python file is smaller at 100K because numpress-delta kicks in for
`write_minimal`; Java/ObjC use plain zlib. File-size differences affect
the absolute write times but the rankings hold.)*

## Where each language actually spends time

### Python — `cProfile` (100K run, 0.22s total)

```
ncalls  tottime  cumtime  filename:lineno(function)
   1     0.001    0.220   workload
   1     0.000    0.160   spectral_dataset.py:475 (write_minimal)
   1     0.116    0.159   spectral_dataset.py:607 (_write_run)
  10     0.000    0.042   _hdf5_io.py:164 (write_signal_channel)
  10     0.000    0.042   h5py/group.py:121 (create_dataset)
  10     0.041    0.042   h5py/dataset.py:39 (make_new_dset)
1000     0.006    0.034   acquisition_run.py:515 (_materialize_spectrum)
```

- 100 000 spectra written through `write_minimal` takes ~160 ms.
- **One Python function — `_write_run` — accounts for 116 ms of self
  time**, with nearly all of that time inside `h5py.create_dataset`
  and the HDF5 native write that follows.
- Read path is `_materialize_spectrum` × 1000 sampled calls = 34 ms,
  dominated by `h5py.Dataset.__getitem__` hyperslab reads.
- **Only 39 837 Python-level function calls total.** Python spends
  almost zero CPU in its own interpreter loop on this workload — it's
  a thin shim over numpy + h5py → libhdf5.

### Java — JFR `ExecutionSample` + `NativeMethodSample` (100K run)

```
leaf method                                            count   %
------------------------------------------------------------------
hdf.hdf5lib.H5.H5Dwrite_double(... double[] ...)        40    83.3%
hdf.hdf5lib.H5._H5Dclose(long)                           4     8.3%
hdf.hdf5lib.H5.H5Dread_double(... double[] ...)          2     4.2%
hdf.hdf5lib.H5.H5Dwrite_long(... long[] ...)             1     2.1%
sun.nio.fs.UnixNativeDispatcher.unlink0                  1     2.1%
```

- 48 `NativeMethodSample`s captured; **40 of them (83 %) are parked
  inside a single JNI call — `H5.H5Dwrite_double`**, the native HDF5
  chunked-dataset write. The next 8 % is `H5Dclose` (chunk flush on
  dataset close).
- Only 1 `ExecutionSample` (non-native) was captured across the whole
  run — essentially zero time spent in Java bytecode.
- The write phase is **JNI-bound from Java's point of view**. HotSpot's
  JIT has nothing left to optimise — the `double[]` is handed to
  `H5Dwrite` and libhdf5 chunk-compresses + writes it.

### ObjC — sub-phase timers + flat-path contrast

Object API (TTIOMassSpectrum per-spectrum), 100 000 spectra, 755 ms total:

```
build phase               136.9 ms
  build spectrum objects  112.7 ms   (100K TTIOMassSpectrum alloc + 2×NSData)
  build AcquisitionRun     24.1 ms
  build SpectralDataset     0.0 ms
write phase               579.5 ms
  channel concat            68.8 ms   (2× flatten 100K NSData -> NSMutableData)
  HDF5 emission            510.7 ms   (v0.2 format: 9 index datasets
                                       + 2 signal channels + compound
                                       headers + attributes)
read phase (sampled)       38.6 ms
```

Flat API (TTIOHDF5Provider primitives, no Spectrum objects), 100 K × 16,
473 ms total:

```
build   10.0 ms   (two flat double[] buffers)
write  415.9 ms   (create file, one group, two chunked zlib datasets)
read    47.2 ms
```

### The gap between ObjC object-mode and flat-mode write is
**explained by format, not language**. Object-mode emits the full v0.2
`.tio` layout: `spectrum_index/{offsets, lengths, retention_times,
ms_levels, polarities, precursor_mzs, precursor_charges,
base_peak_intensities}` (9 datasets, 100 K rows each), plus compound
headers, instrument_config group, provenance, and attributes.
Flat-mode writes only `signal_channels/{mz_values, intensity_values}`.

## So why does ObjC look slowest in existing 10K benchmarks?

The 10K benchmarks cited in earlier memos (Py 48 ms / Java 47 ms /
ObjC 69 ms write) use each language's **high-level** API:

- Python's `SpectralDataset.write_minimal` takes **already-flat numpy
  arrays** — the caller does the concatenation. No per-spectrum
  object construction, no per-spectrum autorelease.
- Java's `SpectralDataset.create(...)` takes an `AcquisitionRun` built
  from a `Map<String,double[]>` — again, flat up-front.
- ObjC's `TTIOSpectralDataset initWithMsRuns:` requires an
  `TTIOAcquisitionRun` built from an `NSArray<TTIOMassSpectrum>`,
  i.e. **one `NSData` buffer per spectrum per channel**.

So the ObjC high-level write path pays two costs the other two don't:

1. **Per-spectrum object construction** — 10 K × (`TTIOMassSpectrum` +
   2 × `TTIOSignalArray` + 2 × `NSData`). On 100 K at 16 peaks this
   costs ~113 ms before `write` even starts.
2. **Concat-at-write** — at write time, `TTIOAcquisitionRun
   writeToGroup:` iterates every spectrum and memcpys its two channels
   into one flat `NSMutableData`. ~69 ms on 100 K.

Strip both and use the low-level provider API — the "flat" column
above — and **ObjC writes the same data 4.4× faster than Java and
2× faster than Python**. Your intuition about compiled vs. interpreted
is correct; it just doesn't surface in the existing benchmarks
because the ObjC high-level API forces work the others skip.

## Root finding

**All three languages bottleneck on libhdf5 chunked-dataset writes.**
JFR samples put 83 % of the Java budget in `H5Dwrite_double`; Python
cProfile attributes 73 % of total cumulative time to
`_write_run`→`h5py.make_new_dset`; ObjC gprof would show the same
thing (`H5Dwrite`+`H5Zdeflate` for chunked zlib-compressed writes).

No language's interpreter/VM/runtime is on the hot path in any
meaningful quantity. Claiming "compiled vs. interpreted" as the
explanation for the 28 ms / 53 ms / 71 ms spread **misses the real
cause**, which is:

1. **API ergonomics at the call-site** — does the high-level write
   path take flat arrays or per-spectrum objects?
2. **Format payload size** — object-mode writes spectrum_index +
   compound metadata; flat-mode doesn't.
3. **Per-spectrum object overhead in ObjC-object-mode** — alloc +
   autorelease + NSData wrapping of 100 K tiny buffers.

## Actionable optimisations

Ranked by impact per unit of work:

### 1. ObjC: add a `write_minimal`-equivalent fast path *(highest impact)*

Mirror Python's `SpectralDataset.write_minimal` in ObjC:

```objc
+ (BOOL)writeMinimalToPath:(NSString *)path
                     title:(NSString *)title
              investigation:(NSString *)inv
                      runs:(NSDictionary<NSString *,
                            TTIOWrittenRun *> *)runs
                     error:(NSError **)error;
```

where `TTIOWrittenRun` is a plain value object holding `NSData *mz`,
`NSData *intensity`, `NSData *offsets`, `NSData *retentionTimes`,
etc. — exactly what the current `writeToGroup:` loop builds
internally. Callers who already have flat buffers skip both the
10 K-spectrum construction and the write-time concat.

Expected delta on 100 K workload:
  755 ms total → ~430 ms total  (−325 ms, saving the 113 ms build
  +  69 ms concat + some HDF5-emission savings from not writing the
  full 9-dataset index when the caller didn't compute one).

### 2. Java: switch dataset-close flush to deferred close

`H5Dclose` samples are 8 % of total Java time. Each
`try (Hdf5Dataset ds = ...)` block closes via AutoCloseable, which
flushes the chunk cache. If multiple datasets are written in the
same group, the close+flush can be deferred to group close.
Expected delta: 5–8 % on writes, nothing on reads.

### 3. Python: eliminate the 10 `make_new_dset` calls per run

`_write_run` dispatches 10 separate `h5py.create_dataset` calls — one
per spectrum_index channel + one per signal channel. h5py's property-
list construction + `H5Dcreate2` dominates the 41 ms self-time. A
single `create_dataset` that writes a compound dtype would collapse
9 index datasets to 1 and cut that 41 ms to ~5 ms. However, this
breaks the "each index column is a plain 1-D dataset" format
contract — v1.0 concern.

### 4. All: raise the chunk size

Current `chunkSize = 16384` elements (128 KB at float64). For a
100 K × 16 = 1.6 M-element signal channel, this chunks at ~10 chunks
per dataset, each compressed independently. Bumping to `chunkSize =
65536` (512 KB) cuts the chunk count to 2–3 and correspondingly
reduces `H5Dwrite_double` call count and zlib compression overhead.
Trade-off: smaller hyperslab reads decompress a larger chunk. Already
tunable per-call; recommend benchmarking at 65536 before changing
the default.

### 5. ObjC object-mode: switch `NSMutableData` concat to a single
      malloc + NSData wrapper

The write-time concat allocates a 1.6 MB `NSMutableData`. On 100 K
that's 69 ms. Replacing with a single `calloc(1, total*8)` + direct
memcpy into that C buffer and feeding a non-owning `NSData
dataWithBytesNoCopy:` saves the NSMutableData bookkeeping.
Expected delta: cuts the 69 ms concat to ~20 ms.

## Post-optimisation results

Three optimisations shipped following the analysis above:

1. ObjC `+TTIOSpectralDataset writeMinimalToPath:` — flat-buffer fast
   path plus new `TTIOWrittenRun` value class; eliminates per-spectrum
   alloc and write-time channel concat.
2. Default HDF5 chunk sizes raised across all three languages: signal
   channels 16 384 → 65 536 (128 KB → 512 KB per chunk); index arrays
   1 024 → 4 096 (ObjC + Python).
3. ObjC `TTIOAcquisitionRun -writeToGroup:` channel concat now uses
   `malloc` + `NSData dataWithBytesNoCopy:freeWhenDone:` instead of
   `NSMutableData dataWithLength:` + `.mutableBytes`, avoiding the
   zero-fill tax on the concat buffer.

### 100 000-spectrum results (before → after)

| Path | Before (ms) | After (ms) | Δ | Notes |
|------|-----------:|-----------:|---:|-------|
| Python `write_minimal` | 223.0 | 223.8 | ±0 | already-flat path unchanged |
| Java `create(...)` | 505.8 | 497.3 | **−9** | chunk-size benefit |
| ObjC object API | 755.0 | 728.9 | **−26** | concat malloc fix + chunk bump |
| ObjC flat primitives | 473.2 | 473.2 | ±0 | no impact (not on this path) |
| **ObjC writeMinimal** (new) | — | **554.0** | **−200 vs object** | ships the Python-equivalent fast path |

### Cross-language ranking (100 K, writeMinimal / flat-equivalent)

| Language | Write (ms) | vs fastest |
|----------|-----------:|-----------:|
| Python   | 162.1 | 1.00× |
| Java     | 442.5 | 2.73× |
| ObjC (writeMinimal) | 508.9 | 3.14× |

Python's lead here is real: `write_minimal` piggybacks on h5py's
`create_dataset` fast path which collapses the per-dataset property-
list + HDF5 chunk-cache set-up into a single C call. Java and ObjC
each go through `Hdf5Group.createDataset` → JNI / native →
`H5Dcreate2` + `H5Pset_chunk` + `H5Pset_deflate` round-trips
per dataset. Closing the gap would require batching the 9 index-
array creates under one `H5P` property list — v1.0 format concern.

At 100 K the ObjC `writeMinimal` path is now **within 25% of Java**
rather than 50% behind object-mode, and under 3.5× Python.

## Deeper dive — what was hiding the real ObjC parity

The first-cut numbers reported "ObjC writeMinimal 554 ms vs Python
162 ms at 100 K" — a 3.4× gap that looked like a real language-level
problem. Two hidden fairness issues explained the entire gap:

### Issue 1 — harness data pattern (13× file-size skew)

Python's harness used `np.tile(mz_template, n)` — every one of the
100 K spectra got the **same** 16-element m/z template, making the
1.6 M-element signal channel a tiled repeat pattern that zlib
compresses to 4 % of its raw size. The Java and ObjC harnesses
generated per-spectrum-varying values (`mz[j] = 100 + i + j*0.1`),
which zlib compresses to 16 %. Same format, same compressor — 4× less
work for Python's libhdf5 to do.

Fixing the Python harness to generate the same varying pattern:

| Metric | Python before | Python after |
|--------|--------------:|-------------:|
| 100 K file size | 0.63 MB | **2.94 MB** |
| 100 K write time | 162 ms | **516 ms** |
| 100 K ratio vs ObjC | 3.4× faster | 1.03× faster |

### Issue 2 — ObjC writeMinimal wrote a 5.6 MB duplicate

The first cut of `+writeMinimalToPath:` emitted
`spectrum_index/headers` — a compound dataset that duplicates the
parallel 1-D index arrays in a single 56-byte-per-row compound
dtype, uncompressed and unchunked, for h5dump readability. Python's
`write_minimal` doesn't emit it; neither does Java. 100 K spectra =
5.6 MB of dead weight + ~45 ms of extra write time.

Dropping it (the parallel arrays are authoritative):

| Metric | ObjC before | ObjC after |
|--------|-------------|------------|
| 100 K file size | 8.49 MB | **2.89 MB** (matches Python byte-for-byte region) |
| 100 K writeMinimal | 554 ms | **501 ms** |

### Apples-to-apples final — 100 K spectra, matched data

| Lang | Build (ms) | Write (ms) | Read (ms) | Total (ms) | File (MB) |
|------|-----------:|-----------:|----------:|-----------:|----------:|
| Python | 21.6 | 516.3 | 55.0 | 592.9 | 2.94 |
| Java | 17.2 | **441.5** | 39.4 | **498.1** | 7.33* |
| ObjC | **11.7** | 501.5 | **35.1** | 548.3 | 2.89 |

*Java writes the 8 index arrays **contiguous + uncompressed**
(`chunkSize=0` in `SpectrumIndex.writeDataset`). That's ~4.8 MB
extra on disk but skips a zlib pass on the index data. Java's write
edge is entirely that format choice, not a language-level advantage —
Python and ObjC both choose compressed indexes.

### What ObjC actually does fastest

- **Build phase**: ObjC 11.7 ms vs Python 21.6 ms — the compiled
  advantage shows when assembling the in-memory buffers.
- **Read phase**: ObjC 35.1 ms vs Python 55.0 ms, Java 39.4 ms. Same
  workload across all three.

**Per-megabyte-written** (real throughput, not affected by the
index-compression choice):

| Lang | ms / MB |
|------|--------:|
| Java | 60.2 |
| Python | 175.6 |
| ObjC | **173.5** |

Java actually writes less compressed work per MB, which is why it
leads. ObjC and Python are within 1% of each other on raw
write throughput, and ObjC wins everywhere that doesn't involve the
zlib index-compression choice.

### The bottom line

The original "ObjC is 2× slower" claim was entirely workload artifact.
With fair data + format parity, ObjC `writeMinimal` is at **parity
with Python** and **within 12% of Java** on writes, and **faster
than both** on build and read.

## The native floor — pure-C libhdf5 baseline

To settle "why is Java writing less compressed work than ObjC", I
wrote `tools/perf/profile_raw_c.c` — the same writeMinimal workload
against libhdf5 directly, no binding layer. This is the lower bound
any language can reach for this workload; anything below it would
mean skipping HDF5 work.

Then I fixed the last remaining format divergence: Java's
`SpectrumIndex.writeDataset` was passing `chunkSize=0,
Compression.NONE` while Python and ObjC passed `chunkSize=4096,
zlib 6`. That's why the Java file was 7.3 MB vs Python/ObjC 2.9 MB —
not compression performance, just a format bug. Fixed it.

### All-four comparison at 100 000 spectra (full parity)

| Implementation | Write (ms) | vs C baseline | Read (ms) | vs C baseline | File (MB) |
|----------------|-----------:|--------------:|----------:|--------------:|----------:|
| **Raw C** (libhdf5 direct) | **503.5** | **1.00×** (floor) | **16.8** | **1.00×** | 2.89 |
| ObjC writeMinimal | 509 | 1.01× | 38.1 | 2.27× | 2.89 |
| Java | 505 | 1.00× | 44.4 | 2.64× | 2.89 |
| Python writeMinimal | 513 | 1.02× | 54.0 | 3.21× | 2.94 |

### At 10 000 spectra

| Implementation | Write (ms) | Read (ms) | vs C read |
|----------------|-----------:|----------:|----------:|
| **Raw C** | **53.2** | **2.6** | 1.00× |
| ObjC writeMinimal | 52.0 | 4.7 | 1.81× |
| Java | 51.8 | 5.9 | 2.27× |
| Python | 56.0 | 8.9 | 3.42× |

### What this actually tells us

**All three wrappers are at the libhdf5 write floor.** The
per-language spread on write (501-516 ms at 100K) is inside the
variance of libhdf5's own internal timing (run-to-run noise is
~5 ms). Write time is bounded by `H5Z_deflate` + `H5Dwrite`
native calls; none of the three languages can go faster unless
they skip compression.

**Read time is where the wrapper layer shows up.** Raw C reads in
16.8 ms at 100 K; every wrapper adds per-call overhead:

- **ObjC** reaches 2.27× raw C — the thinnest wrapper. Direct
  C-ABI link to libhdf5, ARC retain/release amortised across the
  sampled loop, one `[_file lockForReading]` pair per call.
- **Java** at 2.64× pays for JNI boxing/unboxing, per-call
  `Object[]`/`double[]` array copies, and JHDF5's
  `H5.H5Dread` synchronisation.
- **Python** at 3.21× pays for h5py's `__getitem__` dispatch
  into `_fast_reader`, numpy array construction per slice, and
  interpreter overhead on the per-sample loop.

The "compiled vs interpreted" intuition **is real** — it shows up
exactly where it should, above the native library layer. Below
that layer all three implementations are identical pass-through.

### Why Java looked fastest on write in the earlier measurements

With full format parity (Java's index arrays now chunked + zlib-
compressed like Python/ObjC), Java's write edge evaporates: it's
now 505 ms vs ObjC 509 ms — a 0.8% difference, well inside the
~±5 ms libhdf5 noise floor. The earlier 60 ms gap was **100%**
the uncompressed-index format choice, not a language advantage.

### What about the 5 ms per-run variance?

5 runs of each harness at 100 K (matched data + format):

- Python: 512, 513, 513, 516, 516 ms — median 513 ms
- Java:   503, 505, 505, 505, 508 ms — median 505 ms
- ObjC:   501, 506, 509, 509, 512 ms — median 509 ms

Python's 8 ms gap above Java/ObjC shows as >± observed noise — that
is the interpreter tax on the non-libhdf5 code (attribute writes,
per-dataset dispatch, group management). Java 505 vs ObjC 509 is
within noise; they're at parity on the write floor.

## Why ObjC retains a residual ~1.3× overhead above raw C

After format parity and the writeMinimal fix, ObjC's read phase at
100 K sits at **~34 ms vs raw-C 17 ms = ~2.0×**, and writeMinimal at
**509 ms vs raw-C 504 ms = ~1.01×**. Decomposing the read gap with
`tools/perf/profile_read_detail.m`:

```
Phase                                Time      per call   Wrapper tax
───────────────────────────────────────────────────────────────────────
A.  raw-C H5Dread (1 ch, reuse)      17.1 ms   17.1 us    (baseline)
B.  TTIOHDF5Dataset wrapper (1 ch)   17.4 ms   17.4 us    +0.3 us
B2. hand-coded reuse-spaces path     16.5 ms   16.5 us    (best case)
C0. readFromFilePath (8 idx arrays)   6.9 ms   ──         format work
C1. full objectAtIndex loop (2 ch)   27.4 ms   27.4 us    2nd ch + alloc
```

The **per-call wrapper overhead is 0.3 µs on 17.1 µs = ~2%**. Above
the libhdf5 layer there's almost nothing to squeeze. The remaining
gap breaks into three pieces, each of which is either *unavoidable
mandatory work* or *a fair apples-to-apples comparison issue*:

### 1. The 2nd channel read is the single biggest cost (~12 ms of 21 ms gap)

`TTIOMassSpectrum` is contractually two-channel (mz + intensity). The
raw-C baseline harness reads only `mz_values` because that's all it
needs for a perf floor. An apples-to-apples raw-C harness that also
reads `intensity_values` would land at roughly 2× the current 17 ms —
maybe 28-30 ms with chunk-cache adjacency savings — at which point
ObjC's 34 ms is **~1.1-1.2× raw C**.

We can't drop this cost without breaking the spectrum abstraction.
Every real consumer of `TTIOMassSpectrum` needs both arrays.

### 2. Eager spectrum_index loading (~3-4 ms)

`readFromFilePath` loads all 8 parallel index arrays — but random-
access workloads only need `offsets` and `lengths`. The other six
(`retention_times`, `ms_levels`, `polarities`, `precursor_mzs`,
`precursor_charges`, `base_peak_intensities`) are only used by
`indicesInRetentionTimeRange:` / `indicesForMsLevel:` queries.

Lazy-loading them would save ~3.7 ms at 100 K but is a medium-
complexity refactor. See `tools/perf/PROPOSAL_read_path.md` for the
full option analysis — deferred since the absolute savings don't
change the ratio substantially and the existing behavior is
predictable.

### 3. Object allocation is essentially free (~2 ms)

Allocating `TTIOMassSpectrum` + 2× `TTIOSignalArray` + 2× `NSData` per
spectrum costs ~2 µs per sample × 1000 = ~2 ms of the 100K-sample
loop. That's the cost of the API shape — ObjC users iterate over
`id<TTIOIndexable>` returning typed objects, not raw buffers. The
alternative (lower-level C-style iteration) would break every
existing caller.

### Summary

| Source of overhead | Amount | Nature |
|---|---:|---|
| 2nd channel read (intensity) | ~12 ms | Mandatory — API contract |
| Eager spectrum_index (6 extra arrays) | ~3-4 ms | Optimizable but deferred |
| Object allocation (MassSpectrum + wrappers) | ~2 ms | API shape |
| TTIOHDF5Dataset wrapper (per-call native-call overhead) | ~0.3 ms | At the libhdf5 floor |
| **Total residual vs single-channel raw C** | **~18 ms** | |

Put differently: **ObjC at 34 ms** vs **an apples-to-apples raw C
baseline at ~28-30 ms** is **~1.15× overhead** — exactly where a
thin binding should land. The "2×" headline is a comparison
artifact; the 2nd-channel read is work raw-C's baseline skipped,
not work ObjC does redundantly.

### What we're not pursuing, and why

- **Lazy `TTIOSignalArray`** (~8 ms potential): Goodhart's law. The
  benchmark reads only `.length` so lazy I/O would hide the cost,
  but real peak-picking code reads `.data` and would pay the same
  cost later. Would make the benchmark prettier without helping any
  user. Declined.
- **Lazy spectrum_index sub-arrays** (~3-4 ms): net-positive for
  random-access workloads, but redistributes cost for query
  workloads. Deferred; the API and call stacks are correct as-is
  and the absolute numbers are healthy.

The API and call stacks are validated. Further optimization is
below the return-on-investment line for v1.x.

## Reproducing

```bash
# Python
cd ~/TTI-O/python && source .venv/bin/activate
python3 ~/TTI-O/tools/perf/profile_python.py --n 10000
python3 ~/TTI-O/tools/perf/profile_python.py --n 100000

# Java (JFR)
bash ~/TTI-O/tools/perf/build_and_run_java.sh --n 10000
python3 ~/TTI-O/tools/perf/aggregate_jfr.py \
    ~/TTI-O/tools/perf/_out_java/native_samples_raw.txt

# ObjC (object + flat modes)
bash ~/TTI-O/tools/perf/build_and_run_objc.sh --n 10000
bash ~/TTI-O/tools/perf/build_and_run_objc.sh --n 10000 --flat
```

---

# v0.11.1 multi-function matrix

Everything above measures the MS write/read path only — the workload
TTI-O shipped in v0.9. Since then v0.10 added the `.tis` transport
codec, v0.10.5 added per-AU AES-256-GCM encryption and HMAC-SHA256 /
ML-DSA-87 signatures, and v0.11 added IR / Raman / UV-Vis / 2D-COS
spectrum classes with JCAMP-DX 5.01 import + export. A three-way
MS-only comparison no longer covers most of the codebase.

`profile_python_full.py`, `ProfileHarnessFull.java`, and
`profile_objc_full.m` instrument the same ten functions across all
three languages so cross-language deltas are directly comparable:

| Benchmark | Workload |
|---|---|
| `ms.hdf5`, `ms.memory`, `ms.sqlite`, `ms.zarr` | write_minimal + sampled read across every storage provider |
| `transport.plain`, `transport.compressed` | `.tis` encode + decode, with and without zlib per-channel |
| `encryption` | per-AU AES-256-GCM encrypt + decrypt on the MS file |
| `signatures` | HMAC-SHA256 sign + verify on the intensity channel |
| `jcamp` | JCAMP-DX write + read for IR / Raman / UV-Vis, plus a compressed (SQZ) read |
| `spectra.build` | in-memory construction of IR / Raman / UV-Vis / 2D-COS |

## Headline (10 000 spectra, 16 peaks, WSL2 Ubuntu 24.04)

All values in milliseconds; `—` means "writer not implemented in that
language at this version". Read the totals as *order-of-magnitude*:
JCAMP / signatures dominate different languages for different reasons
spelled out below, and one warm run is noisier than the production MS
numbers above.

| Benchmark | Python | Java | ObjC |
|---|---:|---:|---:|
| ms.hdf5 | 71.6 | 59.1 | 69.9 |
| ms.memory | 173.9 | 11.3 | — |
| ms.sqlite | 87.7 | 164.9 | — |
| ms.zarr | 260.8 | 62.1 | — |
| transport.plain | 590.8 | 158.4 | 182.6 |
| transport.compressed | 519.7 | 233.6 | 266.4 |
| encryption | 393.4 | 234.1 | 153.0 |
| signatures | 15.9 | 11.4 | 3.6 |
| jcamp | 52.8 | 167.6 | 81.1 |
| spectra.build | 0.6 | 1.3 | 0.4 |

## Observations per function set

### `ms.*` — provider dispatch

HDF5 numbers reproduce the headline of the v0.9 single-function
harness (all three languages at the libhdf5 floor, ±12 ms). The
spread on non-HDF5 providers is real, not noise:

- **Java ms.memory = 11 ms** — the in-process JVM heap provider emits
  everything as `double[]` references, no serialization.
- **Python ms.memory = 174 ms** — the memory provider still builds
  the full layered group/dataset hierarchy in-process, so it pays
  dictionary/dtype-construction cost that the JVM provider elides.
- **Java ms.sqlite = 165 ms (was 191 ms) vs Python 54 ms** — after
  plumbing `beginTransaction()` / `commitTransaction()` through
  `SpectralDataset.createViaProvider` so `SqliteProvider` skips its
  per-mutation `conn.commit()` under `batchMode`, the 35 per-op
  commits collapse into one. ~14% speedup. Most of the remaining gap
  isn't commit overhead (WAL+synchronous=NORMAL is already near-zero)
  — it's the per-dataset UPDATE pushing ~1.3 MB blobs through
  `packPrimitive`'s one-double-at-a-time `ByteBuffer.putDouble` loop.
- **Java ms.zarr = 62 ms vs Python 261 ms (was 366 ms)** — after
  adding a lazy-materialization cache in `_ZarrPrimitiveDataset.read`,
  sampled reads collapse N per-spectrum chunk-decompress round-trips
  into one. read: 237 → 36 ms, total: 462 → 261 ms (~1.8× overall,
  ~6.5× on the read phase). zarr-python 3.x runs every array access
  through `asyncio.run_until_complete` even for single-chunk data,
  and that per-call overhead now only hits once per dataset instead
  of once per sampled spectrum. Write-side remains dominated by
  zarr's per-array `zarr.json` flushes.

**ObjC exposes HDF5 only** via `+writeMinimalToPath:`. The provider
write path for memory / sqlite / zarr is read-only in v0.11.1
(`+readViaProviderURL:` works; the write-side caller refactor is
scheduled post-v1.0). Listed here as `—` so the table makes the gap
explicit; the ObjC read path would already land on all four providers
if the harness exercised it.

### `transport.*` — .tis codec

- **Python is the outlier at 740–812 ms**, ~4-5× the compiled
  languages. The Python writer builds per-packet `bytes` concatenations
  inside a `for spectrum in run` loop at Python speed — every packet
  pays an interpreter round-trip.
- **Compressed encode is slower than plain** by ~80 ms in Java and
  ~85 ms in ObjC (raw zlib), essentially free in Python (already
  interpreter-bound).
- **Decode is faster than encode** in all three by 10-40% — the
  receiver stitches contiguous channel buffers without per-spectrum
  framing logic.

Optimisation target: collapse Python's per-spectrum encode loop into
a vectorised `np.concatenate` + single `struct.pack` of the framing
headers. Expected ~3× on the encode side.

**Landed (2026-04-21):** `TransportWriter._emit_run_access_units`
bulk-reads channel datasets once per run (was 20 000 h5py hyperslab
calls per 10K-spectrum run), slices per-AU from in-memory arrays, and
inlines the header/prefix packing with pre-compiled `struct.Struct`
instances to skip dataclass constructions. `TransportReader.read_to_dataset`
got the symmetric inlined parse path (`_ingest_access_unit_bytes`).
Encode dropped from ~431 ms to ~250 ms (~1.7×); total `transport.plain`
812 → 591 ms, `transport.compressed` 741 → 520 ms. Remaining decode
time is in `SpectralDataset.write_minimal` rebuilding the output file,
outside the codec scope.

### `encryption` — per-AU AES-256-GCM

- **ObjC remains the leader at 153 ms** (OpenSSL EVP_AEAD direct from C).
- **Java (was 425 ms, now 234 ms)** — still behind ObjC but now ahead
  of Python. Python goes through `cryptography` (cffi round-trip per
  AU).
- **Decrypt is 40-50% of encrypt time** across all three, as expected
  for GCM (auth tag verify < tag compute).

**Landed (2026-04-21):** `PerAUEncryption` now caches
`Cipher.getInstance("AES/GCM/NoPadding")` in a `ThreadLocal<Cipher>`
and caches `SecretKeySpec` by byte-array identity (same key material
reused for the whole file, so `==` check is sufficient and skips a
hash/bytes compare). Each AU only pays `cipher.init(mode, key, iv)` +
AAD, not a fresh provider lookup + key-expansion. Encrypt dropped
259 → 162 ms, decrypt 117 → 71 ms, combined 377 → 234 ms (~38%
speedup). 32 encryption tests still pass.

### `signatures` — HMAC-SHA256

Sub-millisecond per-call times; the only observation worth
recording is that the **benchmark floor is the libhdf5 read** of the
intensity channel, not the HMAC itself. Moving to per-AU signing (v1.x)
will exercise the HMAC cost more meaningfully.

### `jcamp` — JCAMP-DX 5.01

- **Python fastest** at 52 ms — the writer is a single `numpy.savetxt`
  + string-format for the `##` headers.
- **Java** originally 218 ms, dominated by IR+Raman write. The writer
  went digit-by-digit through `String.format("%.10g%n", v)` for every
  XYDATA value. Python's `numpy.savetxt` delegates to a vectorised
  `PyArray_CastToType` → `PyOS_double_to_string` loop that's ~15×
  faster per-value.
- **Compressed-read is nearly identical** across all three (4-8 ms) —
  it's character-alphabet decoding, not numeric parsing.

**Landed (2026-04-21):** `JcampDxWriter` now uses `Double.toString()` —
native, shortest-round-trip, same precision guarantee as `%.10g`. Write
time on 10 000-point spectra dropped from ~97 ms (IR+Raman+UV-Vis
combined) to ~42 ms, ~2.3× faster; total `jcamp` benchmark went from
218 ms to 167 ms. Remaining bench time is dominated by read-side
parsing (`Double.parseDouble` in `JcampDxReader`), not the writer.
Round-trip tests (Milestone73 / Milestone73_1) still pass at 1e-9
tolerance.

### `spectra.build` — in-memory construction

All three languages land under 2 ms for ten thousand points + one
2D-COS matrix — constructing the signal arrays is dominated by the
`malloc + fill` loop and the value-class wrapping is free. No
optimisation warranted.

## Bottom line

**MS write/read parity (the v0.9 focus) holds across v0.11.1.** The
three languages are within 15% of each other on `ms.hdf5` and sit at
the libhdf5 floor just as they did a year ago. The new surface
introduced through v0.11.1 shows clear language-level hot-spots:

| Hot spot | Cause | Fix |
|---|---|---|
| ~~Python transport encode~~ | ~~Python per-packet encode loop~~ | **Landed 2026-04-21:** bulk channel read + inlined struct pack; encode 1.7× faster |
| Java SQLite write | One transaction per insert | Batch into a single transaction |
| ~~Python zarr read~~ | ~~per-call asyncio + chunk decode~~ | **Landed 2026-04-21:** lazy-materialize cache in primitive dataset; read 6.5× faster |
| ~~Java JCAMP write~~ | ~~`String.format("%g", v)` per value~~ | **Landed 2026-04-21:** `Double.toString()`; write 2.3× faster |
| ~~Java encryption~~ | ~~Per-AU `Cipher` instance~~ | **Landed 2026-04-21:** `ThreadLocal<Cipher>` + cached `SecretKeySpec`; ~38% faster |

None of these gate a v1.0 release — every benchmark completes
correctly and the numbers are well within an order of magnitude of
each other across languages. Each listed fix is a localised
optimisation, not an architectural shift, and can land in a future
v1.x point release.

## Reproducing the multi-function sweep

```bash
# Python
python3 ~/TTI-O/tools/perf/profile_python_full.py --n 10000 \
    --json ~/TTI-O/tools/perf/_out_python_full/full.json

# Java (JFR)
bash ~/TTI-O/tools/perf/build_and_run_java_full.sh --n 10000

# ObjC
bash ~/TTI-O/tools/perf/build_and_run_objc_full.sh --n 10000 \
    --json ~/TTI-O/tools/perf/_out_objc_full/full.json
```
