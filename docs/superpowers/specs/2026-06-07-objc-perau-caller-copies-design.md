# ObjC per-AU encryption caller-side copy elimination (Copy #1 + #2) — Design

**Date:** 2026-06-07
**Origin:** after PR #257 (writeGeneric zero-copy) the ObjC spectral `encryption.encrypt` is ~688ms
vs Java ~270ms. The remaining gap is caller-side: the per-AU segment objects copy the cipher
bytes (Copy #1) and `writeChannelSegments` re-boxes everything into `NSDictionary` rows + NSNumber
(Copy #2) before the (now zero-copy) `writeGeneric`.
**Scope:** Two independent caller-side optimizations on the per-AU encryption write path. SDK
product code. **HARD invariant: byte-identical on-disk output, cross-SDK conformance preserved,
no wire/format change.** Two commits, each independently measurable/revertable.

## Copy #1 — segment retain instead of copy (`TTIOPerAUEncryption.m`)
`TTIOChannelSegment`/`TTIOHeaderSegment` `initWith...` do `_iv=[iv copy]; _tag=[tag copy];
_ciphertext=[ciphertext copy]` (`:46-48`, `:59-61`). The properties are already declared
`(nonatomic, readonly, strong)` in `TTIOPerAUEncryption.h:29-31,58-60` — so the `[copy]` is a
REDUNDANT defensive copy, not required by the contract. The iv/tag/ciphertext are freshly
allocated per AU by the EVP helpers (random IV, fresh tag, fresh ciphertext) and never mutated
after construction.
**Change:** assign directly (`_iv = iv;` etc.) — a strong retain, matching the declared
`strong` semantics. Eliminates ~600K small NSData copies (~31MB) per encryption run.
**Safety to confirm:** the inputs are immutable/owned-fresh (the EVP helper returns a new NSData
each call; no buffer reuse across AUs). Verify the encrypt loop doesn't pass a single reused
mutable buffer. If any caller passes NSMutableData it could mutate, keep `[copy]` there — but the
per-AU loop uses fresh NSData, so retain is safe.

## Copy #2 — column-oriented write for channel segments (`TTIOPerAUFile.m` + `TTIOCompoundIO.m`)
`writeChannelSegments` (`TTIOPerAUFile.m:160-169`) builds one `NSDictionary` per AU with NSNumber
boxing of offset/length, then `[ds writeAll:rows]` → `TTIOCompoundIO writeGeneric` which looks up
`row[fieldName]` per field per row. At 100K rows × 2 channels that's ~100K dicts + ~200K NSNumbers
+ ~500K dict lookups per channel.

**Change:** add a column-oriented entry to `TTIOCompoundIO` and use it from `writeChannelSegments`,
avoiding the per-row dictionary entirely:
- New: `+[TTIOCompoundIO writeColumnar:(NSDictionary<NSString*, id> *)columns
  intoGroup:datasetNamed:fields:count:error:]` where each field's column is:
  - primitive (Int64/UInt32/Float64): an `NSData` of `count` packed C values, OR an
    `NSArray<NSNumber*>` — prefer packed `NSData` (zero boxing). Pick one and document.
  - VLBytes: `NSArray<NSData*>` of length `count`.
  - VLString: `NSArray<NSString*>` of length `count`.
  It builds the SAME row-major compound buffer as `writeGeneric` (same field offsets, same
  `hvl_t.p`→NSData.bytes zero-copy from #257, same primitive memcpy), just sourced column-wise.
  For non-HDF5 parents, convert columns→`NSArray<NSDictionary*>` rows internally and delegate to
  the existing `createCompoundDatasetNamed:`+`writeAll:` path (rare; not the hot path) so all
  backends keep working.
- `writeChannelSegments`: build the 5 columns from `segments` in ONE pass — offsets into a packed
  `int64` NSData, lengths into a packed `uint32` NSData, iv/tag/ciphertext into three
  `NSArray<NSData*>` (referencing `seg.iv`/`seg.tag`/`seg.ciphertext`, no copy) — then call
  `writeColumnar`. No per-row NSDictionary, no NSNumber boxing.
- Leave other `writeGeneric` NSDictionary callers (genomic `chrom_names`, mate_info) unchanged.

**Byte-identity:** the compound buffer written must be identical whether assembled row-major
(`writeGeneric`) or column-major (`writeColumnar`) for the same logical data — same H5T compound
type, same field offsets, same packed primitive bytes, same VL hvl_t bytes. Verify by writing the
same segments both ways and comparing the on-disk compound dataset bytes.

## Invariants & verification
- Files: `TTIOPerAUEncryption.m` (Copy #1), `TTIOPerAUFile.m` + `TTIOCompoundIO.m` (Copy #2). No
  header/API change to public types; `writeColumnar` is a new internal/SPI method (add to the
  internal TTIOCompoundIO interface, not a public umbrella header).
- **Byte-identity (critical):** per-AU-encrypted file decrypts + round-trips; cross-SDK
  conformance (ObjC↔Py↔Java per-AU + transport) green; a deterministic compound write (no random
  IV) compared row-major vs column-major is byte-identical (h5py content compare, since raw file
  cmp has HDF5 container noise).
- Full ObjC suite `cd objc && ./build.sh check` green (per-AU encryption, M43 cross-backend
  compound byte-identity, genomic/mate_info compound, compound round-trip).
- Memory safety: column NSData/segment NSData kept alive through the H5Dwrite (same `retained`
  mechanism); no UAF/double-free/leak; packed primitive NSData freed/owned correctly.
- Perf: FORCE-rebuild libTTIO (`cd objc && touch <changed>.m && ./build.sh`, verify mtime) +
  `chmod +x tools/perf/*.sh`, then measure `encryption.encrypt` after Copy #1 alone and after
  Copy #2 — report each increment; target movement toward Java's ~270ms. Re-baseline ObjC.

## Success criteria
Copy #1 (retain) + Copy #2 (column-oriented write) landed, byte-identical (conformance + content
cmp), ObjC suite green, measured `encryption.encrypt` improvement reported per-step, ObjC
re-baselined. One PR (2 commits).

## Out of scope
Java `.tio` bloat (#251); Java `Cipher.getInstance` hoist; per-SDK metric_overrides; Python
Cython for the 5 parity-flagged slow paths.
