# ObjC streaming-read per-spectrum perf — Design

**Date:** 2026-06-07
**Origin:** cross-SDK parity dissection — `streaming.read` at n=100000 is ObjC 559ms vs Java 27ms
(~20×) AT EQUAL SCALE (the Java scale bug is fixed separately in #259). Confirmed a genuine ObjC
inefficiency, not a fairness artifact: both SDKs load each full channel column once then slice
per spectrum (Java `readAll`→`double[]`; ObjC `_cachedFullChannels`), equally eager.
**Scope:** Three behavior-preserving fixes to close the per-spectrum gap. SDK product code (2) +
perf harness (1). **HARD invariant: byte-identical reads, cross-SDK conformance + 4501 ObjC tests
green, no wire/format change, no breaking public-API change.**

## Root cause (confirmed, per spectrum, ×100000 ×2 channels)
1. **No per-iteration `@autoreleasepool` (dominant).** The ObjC streaming read loop
   (`tools/perf/profile_objc_full.m` bench_streaming, ~`:1145`) — and `timedMin`'s `op()` — never
   drain, so ~600K–1M autoreleased temporaries (slice NSData, dicts, EncodingSpecs, spectra)
   accumulate across the whole 100K loop. Java's GC reclaims young-gen mid-loop automatically;
   the manual ObjC equivalent is a per-iteration pool, which is missing. A realistic ObjC
   streaming consumer would use one.
2. **Redundant buffer double-copy.** `spectrumAtIndex:` creates a fresh slice via
   `[NSData dataWithBytes:…]` (`TTIOAcquisitionRun.m:1002/1037`), then
   `[[TTIOSignalArray alloc] initWithBuffer:d …]` does `_buffer = [buffer copy]`
   (`TTIOSignalArray.m:38`) — a SECOND alloc+memcpy of a buffer that is already a private copy.
   ObjC does 4 buffer copies/spectrum vs Java's 2.
3. **Per-spectrum `TTIOEncodingSpec`.** A fresh immutable, value-identical `TTIOEncodingSpec` is
   allocated every spectrum (`TTIOAcquisitionRun.m:986`) — 100K needless allocations.

## Design

### Fix A — per-spectrum autoreleasepool in the streaming bench (perf-tooling)
Wrap the body of bench_streaming's read loop (and the write loop) in `@autoreleasepool` so each
iteration's temporaries are reclaimed — the manual analog of Java's automatic young-gen GC, and
what a correct ObjC streaming consumer does. `tools/perf/profile_objc_full.m` only.
(Do NOT wrap `timedMin`'s whole `op()` — that drains only once per rep, AFTER the full 100K loop,
which is too late; the pool must be per-spectrum inside the loop.)

### Fix B — no-copy SignalArray initializer for owned buffers (product, core class)
`TTIOSignalArray initWithBuffer:` keeps its defensive `[copy]` (it is a core class; many callers
pass buffers they may mutate). ADD an initializer variant that takes ownership without copying,
e.g. `-initWithOwnedBuffer:length:encoding:axis:` (or an internal `noCopy:` flag), which stores
the passed NSData directly (`_buffer = buffer`). Use it ONLY where the caller hands a
freshly-allocated, unaliased buffer — `spectrumAtIndex:` (the `dataWithBytes:` slice is brand-new
and referenced nowhere else). All existing `initWithBuffer:` callers are UNCHANGED (still copy),
so no aliasing risk anywhere else. This halves the hot-path buffer copies to match Java.
- The NSData must be immutable/owned: `dataWithBytes:` returns an immutable NSData copy, so
  storing it directly is safe (the SignalArray's `_buffer` is `(copy)`/immutable-contract; storing
  an already-immutable NSData satisfies it). Confirm `_buffer` property semantics and that no
  consumer mutates a SignalArray buffer in place.

### Fix C — hoist the per-spectrum EncodingSpec to a flyweight (product)
In `spectrumAtIndex:`, the `TTIOEncodingSpec` for the standard float64/zlib/LE channel layout is
value-identical every call. Build it ONCE (e.g. a `static` cached instance, or an ivar computed
on first use) and reuse it. `TTIOEncodingSpec` is immutable, so sharing is safe. Removes 100K
allocations.

## Invariants & verification
- Byte-identical reads: the spectra/channels returned are unchanged (same bytes, same lengths,
  same EncodingSpec values). Fix B stores the same bytes without the second copy; Fix C reuses an
  equal spec.
- Files: `tools/perf/profile_objc_full.m` (A); `objc/Source/Core/TTIOSignalArray.{h,m}` +
  `objc/Source/Run/TTIOAcquisitionRun.m` (B, C). New SignalArray init is additive (no breaking
  API change); add to the header.
- `cd objc && ./build.sh check` — ALL green (streaming, random-access spectrumAtIndex,
  M43 cross-backend byte-identity, transport/encryption which also use spectrumAtIndex +
  SignalArray). Cross-SDK conformance green.
- **No-copy safety audit:** confirm no code mutates a SignalArray `_buffer` in place, and that
  `spectrumAtIndex:` is the only caller switched to the owned-buffer init. The default copying
  init stays for everyone else.
- Perf: FORCE-rebuild libTTIO (`cd objc && touch <changed>.m && ./build.sh`, verify mtime) +
  `chmod +x tools/perf/*.sh`; measure `streaming.read`/`write` — target 559→~30-60ms band
  (toward Java's 27ms). Spot-check transport/genomic (share spectrumAtIndex/SignalArray) for
  improvement + no regression. Re-baseline ObjC.

## Success criteria
The three fixes land; `streaming.read` drops from ~559ms toward Java's ~27ms (report measured
number); byte-identical + conformance + 4501 tests green; ObjC re-baselined. One PR.

## Sequencing
Branch off main; the Java streaming scale fix (#259) is independent (touches only the Java
harness + baseline). Re-baseline + open this PR AFTER #259 merges to avoid baseline.json churn.

## Out of scope
Transport/encryption further allocation reduction (separate, diminishing returns); Python Cython;
#251; Java Cipher.getInstance hoist; per-SDK metric_overrides.
