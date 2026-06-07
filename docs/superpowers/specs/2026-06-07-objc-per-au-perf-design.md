# ObjC per-AU performance optimizations — Design

**Date:** 2026-06-07
**Origin:** perf P1e cross-SDK parity findings — ObjC is ~6× slower than Java on
`transport.plain.encode` (980 vs 162ms) and ~3.5× on the spectral `encryption.encrypt`
(942 vs 270ms) at n=100000 AUs. Root-caused (read-only investigation) to per-AU overhead, not
crypto/IO throughput (ObjC's bulk 64MiB AES is *faster* than Java's).
**Scope:** Three behavior-identical ObjC SDK optimizations. **Hard invariants: NO wire/on-disk
format change; NO public-API change; byte-identical encryption output; transport round-trip +
cross-language conformance preserved.** These are pure performance changes.

## Root causes (confirmed by source)
1. **Transport encode** — `TTIOAcquisitionRun spectrumAtIndex:` disk-backed plain-float64 path
   (`Run/TTIOAcquisitionRun.m:991-1001`) reads ONE HDF5 hyperslab per channel per spectrum via
   `[ds readSliceAtOffset:count:]` → ~200,000 hyperslab round-trips (`HDF5/TTIOHDF5Dataset.m`).
   Java loads each whole channel column once and slices in memory.
2. **Spectral encryption** — `TTIOPerAUEncryption.m:138-199` does
   `EVP_CIPHER_CTX_new` → init → `EVP_CIPHER_CTX_free` **per AU** (~200,000 context lifecycles
   over 128-byte chunks). Java caches one `Cipher` and re-`init()`s it per AU.
3. **Amplifier** — neither ObjC per-AU loop wraps iterations in `@autoreleasepool`, so ~1M
   autoreleased temporaries accumulate until the whole op finishes.

## Design

### Fix #2 — reuse the cipher context (encryption)
In `TTIOPerAUEncryption`, create ONE `EVP_CIPHER_CTX` for the per-AU loop and re-key per AU via
`EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, key, iv)` (fresh IV per AU as today), encrypt,
read tag; free the context once after the loop. Same for the decrypt path
(`EVP_DecryptInit_ex`). **Output bytes (ciphertext + 16-byte GCM tag + IV) MUST be identical**
per AU. If the public encrypt entry point is a single-shot `encryptWithPlaintext:` used
elsewhere, keep it; add an internal context-reusing loop variant (or pass an optional reusable
ctx) so the single-shot API is unchanged. Verify with existing per-AU round-trip + the cross-SDK
conformance tests (ObjC-encrypted file must still decrypt in Python/Java and vice versa) AND a
direct byte-compare of an ObjC-encrypted file before/after the change (must be identical).

### Fix #1 — cache whole channel columns (transport / random read)
In `TTIOAcquisitionRun spectrumAtIndex:`, replace the per-spectrum slice read (the `else` branch
at `:991-1001`) with a **lazy per-channel full-column cache**: on first access of a channel,
read the WHOLE column once (the storage protocol's read-all, as the numpress branch already does
at `:822`), retain it as an `NSData` in a new `_cachedFullChannels` dict, then slice it
element-wise — reusing the EXACT existing slice logic at `:988-990`
(`base + off*sizeof(double)`, `len*sizeof(double)`). Subsequent spectra hit the cache (pure
in-memory slice). This:
- kills the ~200,000 hyperslab round-trips for sequential iteration (transport/encryption read);
- is **no more memory-eager than Java** (Java loads all channels at open; this loads only
  accessed channels, lazily) and reuses the same NSData-slice path already proven byte-identical
  by M43 cross-backend tests;
- improves (not harms) random-access percentiles after the first load.
The sliced `NSData` fed to `TTIOSignalArray` must be byte-identical to the previous
per-slice read. Keep the numpress/decrypted-channel branches (`:982-990`) untouched. Ensure the
cache is only used for read-only disk-backed runs (it already only applies when
`_inMemorySpectra == nil`).

### Fix #3 — per-AU autorelease pools
Wrap the per-AU loop BODY in `@autoreleasepool` in (a) the transport writer's spectrum loop
(`Transport/TTIOTransportWriter.m` ~`:1639`) and (b) the per-AU encryption loop
(`TTIOPerAUEncryption.m` ~`:308`). **Correctness:** anything that must outlive the iteration
(the accumulated output bytes / segments appended to the result) MUST be retained/copied into the
outer accumulator before the inner pool drains — verify no use-after-free / dangling autoreleased
results. (ARC is in use; ensure the accumulator holds strong refs, e.g. append `[data copy]`
into a `__strong` collection declared outside the pool.)

## Invariants & verification
- No wire/on-disk format change; no public-API change (single-shot encrypt API unchanged).
- **Byte-identical encryption:** an ObjC-encrypted `.tio` is bit-identical before vs after Fix #2
  (snapshot a small file, compare). Cross-SDK conformance suite green (ObjC↔Python↔Java decrypt).
- **Transport correctness:** `.mots` output byte-identical / round-trips; transport conformance
  green.
- Full ObjC suite green: `cd objc && ./build.sh` (and `./build.sh check` if that's the test
  entry). Cross-language conformance tests pass.
- Re-run perf benches to confirm improvement: `transport.plain.encode` and spectral
  `encryption.encrypt` should drop materially toward Java's numbers (target: well under the
  prior 980/942ms; exact figure measured, not promised).
- ASan/leak sanity if available (the autoreleasepool change is the main leak/UAF risk).

## Success criteria
All three fixes landed, behavior-identical (byte-identical crypto + transport, conformance
green), ObjC suite green, and measured speedups on `transport.plain.encode` and
`encryption.encrypt`. One PR (3 commits, one per fix) — or split if review warrants.

## Out of scope
Java/Python changes; the 5 Python-slow parity flags (separate Cython work); issue #251 (Java
`.tio` bloat); per-SDK metric_overrides; the Java `encryption.genomic` Cipher.getInstance hoist.
