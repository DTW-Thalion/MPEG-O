# Python bulk-read perf fix (4 paths, one read-pattern) — Design

**Date:** 2026-06-08
**Origin:** Python parity-perf — `transport.plain.encode` (2472ms), `ms.read`, `streaming.read`,
and `genomic.read` (1920ms) are 5–12× slower than Java/ObjC because Python does a per-spectrum /
per-read **h5py hyperslab read** instead of bulk-reading each channel once and slicing in memory
(the ObjC/Java fast path). One read-pattern change in two methods fixes all four.
**Scope:** Python SDK product code. **HARD invariant: byte-identical reads, cross-SDK + cross-
backend (M43) conformance preserved, no wire/format/public-API change.** The in-memory-slice
approach is ALREADY used for the decrypted/numpress/compressed branches, which proves byte-
equivalence.

## Confirmed hot spots
- **Spectral:** `acquisition_run.py _materialize_spectrum` (`:708-730`) — the `else` branch
  (`:721-726`) does `np.asarray(ds.read(offset=offset, count=length))` PER spectrum PER channel
  (200K hyperslab reads for n=100000×2 channels). The decrypted/numpress branches (`:714-718`)
  already slice an in-memory full-column array (`_decrypted_channels`/`_numpress_channels`,
  dicts populated at open).
- **Genomic:** `genomic_run.py _byte_channel_slice` (`~:409-459`, line ~445) — uncompressed
  sequences/qualities do a per-read hyperslab `ds.read(offset,count)` (never cached) + a per-call
  `read_int_attr(ds,"compression")` re-reading the HDF5 attr 200K× (`_hdf5_io.py:132`). The
  compressed branch (`~:447-458`) already bulk-reads + caches into `_decoded_byte_channels`.

## Design

### Fix 1 — full-channel cache in `_materialize_spectrum` (spectral; fixes 3 paths)
Add a lazy `_full_channel_cache: dict[str, np.ndarray]` (mirror `_decrypted_channels`,
`field(default_factory=dict, repr=False)`). In the `else` branch: on cache MISS, read the WHOLE
channel column once via the storage protocol (the dataset's full read — `ds.read()` with no
offset/count, or `ds.read(offset=0, count=<full len>)`; use whatever the protocol exposes for a
full read, consistent with how numpress/decrypted got their full arrays), `np.asarray` it, store
in the cache; then slice `[offset:offset+length]`. On HIT, just slice. The sliced array fed to
`SignalArray.from_numpy` MUST be byte-identical to the previous per-slice `ds.read(offset,count)`.
- Keep the decrypted/numpress branches unchanged (they already cache+slice).
- The slice must match exactly: same dtype, same `[offset:offset+length]` element semantics as the
  hyperslab read returned.

### Fix 2 — extend the genomic byte-channel cache to the uncompressed path (fixes genomic.read)
In `_byte_channel_slice`: extend the existing `_decoded_byte_channels` cache (already used by the
compressed branch) to the UNCOMPRESSED path — bulk-read the whole byte channel once, cache, slice
— instead of a per-read hyperslab. Also hoist the per-call `read_int_attr(ds,"compression")` probe
to a one-time determination per channel (read the attr once when the channel is first accessed,
not on every slice). Byte-identical to the current per-read result.

## Cache safety (staleness/memory)
- `AcquisitionRun`/`GenomicRun` are read views; `_decrypted_channels`/`_numpress_channels`/
  `_decoded_byte_channels` are already populated-once dicts with no invalidation, so the new
  full-channel cache follows the same safety model (the underlying datasets are not mutated during
  reads). CONFIRM there's no in-place mutation/reopen path that would make a cached column stale;
  if the run/dataset can be reopened or appended to, invalidate the cache there (mirror the ObjC
  fix). If `AcquisitionRun` is immutable-after-open (likely), no invalidation needed.
- Memory: caches accessed channels (~25MB for the bench), same as Java/ObjC and the existing
  numpress/decrypted caches. Acceptable; lazy (only accessed channels).

## Invariants & verification
- Python product code only (`acquisition_run.py`, `genomic_run.py`; maybe a tiny helper). No
  wire/format/API change.
- **Byte-identity (critical):** `ms.read`/streaming/transport produce identical spectra
  (same channel bytes/dtypes); genomic reads identical sequences/qualities. The cross-backend M43
  byte-identity tests + transport + genomic round-trip + cross-SDK conformance MUST stay green.
- `cd python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so python3 -m pytest -q
  tests/` — all green incl coverage gate; spot-check a few read values vs a pre-change run.
- Perf: re-measure `transport.plain.encode`, `ms.hdf5.read`/`ms.*.read`, `streaming.read`,
  `genomic.read` — expect ~5–10× drops toward Java/ObjC. Re-baseline Python.
- Random-access note: like the ObjC change, caching-on-first-access means a single sparse read now
  loads the whole column once (one-time cost; subsequent reads instant). Confirm `genomic`
  random-access percentiles don't regress meaningfully (they read few records — but the column is
  bounded; acceptable, and Java/ObjC already hold full columns).

## Success criteria
Full-channel cache in both methods; `transport.plain.encode`/`ms.read`/`streaming.read`/
`genomic.read` drop ~5–10× toward Java/ObjC; byte-identical (conformance + M43 green);
Python re-baselined. One PR (2 commits).

## Out of scope
`transport.plain.decode` (own profile); `streaming.write` (low ROI); ObjC/Java.
