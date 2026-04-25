# Proposal: ObjC read path optimizations (analysis only)

**Goal.** Cut ObjC's read phase from 2.3× raw-C down to 1.5×
(38.1 ms → ~25 ms at 100 K spectra).

**Status.** Analysis + prototype measured. Prototype is **not
committed**; stashed as `prototype-cache-spaces-skip-zerofill` for
review. Tree is clean.

## Per-phase attribution at 100 K sampled reads

Harness: `tools/perf/profile_read_detail.m` (new).

```
Phase                                Time       per call   Notes
───────────────────────────────────────────────────────────────────────
A. Raw C H5Dread, 1 channel          17.1 ms    17.1 us    baseline
B. TTIOHDF5Dataset readDataAtOffset  17.4 ms    17.4 us    +0.3 us
B2. Same but hand-coded reuse spaces 16.5 ms    16.5 us    best case
C0. readFromFilePath (alone)          6.9 ms    ──          8 index arrays
C1. full objectAtIndex loop          27.4 ms    27.4 us    2ch + obj alloc
C.  total (C0 + C1)                  34.3 ms                matches bench
```

**Where the 21 ms gap to raw-C lives** (17.1 ms → 38.1 ms):

1. **`readFromFilePath` loads 8 spectrum_index arrays eagerly**: 6.9 ms
   - Only `offsets` + `lengths` (1.8 ms) are needed for random-access
   - The other 6 arrays (`retention_times`, `ms_levels`, etc, totalling
     **3.7 ms**) are query-only and could be lazy
2. **Sampling loop = 27.4 µs/call vs raw-C 17.1 µs/call**: 10.3 ms extra
   - Second channel read (intensity) = most of it
   - Object allocation (MassSpectrum + 2× SignalArray + 2× NSData) = ~1-2 µs/call
   - Chunk cache on adjacent reads helps the 2nd channel (2 × 16 µs would
     be 32 µs, actual is 27.4 µs)

## Four proposed optimizations

### ① HDF5 handle caches in `TTIOHDF5Dataset` — LOW complexity
**What.** Cache filespace, memspace-per-count, and htype inside the
dataset wrapper. Today every `readDataAtOffset:` calls
`H5Dget_space` + `H5Screate_simple` + `TTIOHDF5TypeForPrecision` and
then closes them, even when 1000 consecutive calls use identical
parameters.

**Measured savings (prototyped + run).**
  - Wrapper tax: 0.8 µs/call → 0.1 µs/call
  - At 1000 samples: −0.7 ms (sampling loop)
  - Also applies to `readDataWithError:` (−0.1 ms) and `writeData:` (tiny)

**Abstraction impact.** Zero. Pure internal bookkeeping — cache lazily,
release in `dealloc`.

### ② Skip `NSMutableData` zero-fill — LOW complexity
**What.** `[NSMutableData dataWithLength:bytes]` zero-fills the
backing store before `H5Dread` overwrites every byte. Replace with
`malloc` + `[NSData dataWithBytesNoCopy:freeWhenDone:YES]`.

**Measured savings (prototyped + run).**
  - ~1-2 ms on 100 K sampling loop (combined with ①, both
    optimizations landed together in prototype: 38.1 → 34.8 ms = **−3.3 ms**)

**Abstraction impact.** Zero. Returned `NSData` is still immutable
and owns its buffer.

### ③ Lazy `TTIOSpectrumIndex` sub-arrays — MEDIUM complexity
**What.** Today `TTIOSpectrumIndex +readFromGroup:` reads all 8
parallel datasets up-front. Keep `offsets` + `lengths` eager (needed
for every `spectrumAtIndex:`), defer the other 6 until first
accessor call (`retentionTimeAt:`, `msLevelAt:`, etc.) or first
query (`indicesInRetentionTimeRange:`).

Requires adding a new internal init that retains the source
`TTIOHDF5Group` reference (or a dataset map) plus a per-array
`NSLock`/`once` guard for thread safety.

**Measured savings potential (raw-C detail harness).**
  - Summed cost of 6 lazy-candidate arrays: **3.7 ms** at 100 K
  - 0.5 ms at 10 K

**Abstraction impact.** Minimal. The `TTIOSpectrumIndex` public API is
unchanged; internal storage becomes optionally-deferred. Trade-off:
workloads that DO call `indicesInRetentionTimeRange:` pay the cost at
query time instead of load time — same total, different distribution.

### ④ — *not recommended* — Lazy `TTIOSignalArray`
**What.** Today `spectrumAtIndex:` issues 2 × `H5Dread` (mz + intensity)
even when the caller only touches `.length`. A deferred
`TTIOSignalArray` would carry a reference to the storage dataset and
read on first `.buffer` / `.data` access.

**Potential savings.** ~8-10 ms on 100 K (halves the per-call I/O).

**Why not.** This is a **Goodhart win** — the stress benchmark reads
`.length` only, but real peak-picking / mass-matching workloads read
`.data`. Moving cost from eager to lazy doesn't help those; it just
re-distributes the same work. Shipping it would make the benchmark
number pretty but not help any real user. **Skip.**

## Combined budget

|  | Current | + ① cache | + ② skip zero-fill | + ③ lazy index | Target |
|--|--------:|---------:|------------------:|--------------:|-------:|
| 100 K read | 38.1 ms | (combined with ②) | **34.8 ms** | **~31 ms** | 25 ms |
| vs raw-C | 2.28× | | 2.08× | **~1.85×** | 1.50× |
| 10 K read | 4.7 ms | | **4.3 ms** | **~3.8 ms** | — |
| vs raw-C | 2.14× | | 1.96× | **~1.73×** | — |

**Honest achievable floor: ~1.85× raw-C at 100 K** (31 ms), reachable
without breaking any public abstraction. The gap to 1.5× (25 ms) is
**primarily the 2nd-channel H5Dread** on the `intensity` array — a
legitimate I/O cost that every user actually needs and no amount
of wrapper tuning can remove.

### Why the 1.5× target isn't reachable honestly

Above the libhdf5 layer, the per-call wrapper cost is already
0.3 µs on 17.1 µs of raw C read = ~2%. You can't squeeze what
isn't there. The gap to raw-C exists because:

- The benchmark's raw-C baseline reads **1 channel**, ObjC reads **2**
  (the format promises both mz and intensity are present). This is
  ~12 ms of unavoidable work for any implementation that honors the
  `TTIOMassSpectrum` contract.
- `readFromFilePath` eagerly reads the full 8-array `spectrum_index`;
  lazy-loading drops this to **~3 ms** but doesn't eliminate it.

A fair apples-to-apples raw-C baseline that also reads mz+intensity
+ opens spectrum_index = would likely land around 28-30 ms, at which
point ObjC's 31 ms is **~1.05×** raw-C. The "2.3×" framing compared
apples to oranges; the corrected target of 1.85× or 1.5× depends on
whether you consider the "extra" work part of the job.

## Proposed path forward

1. **Ship ① + ②** as one commit — purely local to TTIOHDF5Dataset,
   high confidence, ~3.3 ms saved, zero abstraction risk. All
   1202 ObjC tests passed with the prototype.

2. **Ship ③** as a follow-up commit — lazy spectrum_index arrays.
   Requires careful refactor of TTIOSpectrumIndex + thread-safety
   guard. Saves ~3.7 ms more. Brings total to ~1.85× raw-C.

3. **Do not ship ④.** Goodhart trap.

Stashed prototype for ① + ② is ready to unstash (`git stash pop` on
stash@{0}, labelled `prototype-cache-spaces-skip-zerofill`).
