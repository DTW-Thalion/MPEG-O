# ObjC `TTIOCompoundIO.writeGeneric` zero-copy optimization — Design

**Date:** 2026-06-07
**Origin:** follow-up to the ObjC per-AU perf work (PR #256). The spectral `encryption.encrypt`
(~825ms vs Java ~270ms) and other per-AU compound writes are bottlenecked not on `H5Dwrite`
(already a single bulk write) but on per-row CPU/allocator marshalling inside the SHARED
`+[TTIOCompoundIO writeGeneric:...]` (`objc/Source/Dataset/TTIOCompoundIO.m:565`).
**Scope:** Optimize `writeGeneric` internally — benefits ALL compound writers (per-AU
encryption segments, genomic per-AU, mate_info, etc.) with NO interface/caller change. SDK
product code. **HARD invariant: byte-identical on-disk output; cross-SDK conformance preserved;
no wire/format/API change.**

## Root cause (confirmed, `TTIOCompoundIO.m:616-678`)
For each of N rows × each field, the HDF5 fast path:
1. **VL_BYTES (`:652-666`):** `malloc(d.length)` + `memcpy(p, d.bytes, d.length)` per row, tracks
   `p` in an `NSValue` in `vlBytesAllocs`, frees each after the write. → ~300K malloc+memcpy +
   300K NSValue per channel (encryption: 2 channels × 100K rows × ~3 VL fields).
2. **Per-row ObjC dispatch:** `[offsets[i] unsignedIntegerValue]` (NSNumber unbox) + `fields[i]`
   / `f.kind` / `f.name` accessed inside the inner row loop though they are invariant per field.

This marshalling is the bulk of `writeGeneric`'s cost and is pure overhead — the same bytes end
up in the same single `H5Dwrite`.

## Design (internal to `writeGeneric`, no signature change)

### A. Zero-copy VL_BYTES
HDF5 variable-length write only READS from `hvl_t.p` during `H5Dwrite` (it copies into its own
global-heap VL storage; it does not modify or take ownership of `p`). So instead of
malloc+memcpy, point `hv.p` directly at the row's `NSData` bytes and keep the NSData alive
through the write:
```objc
NSData *d = [v isKindOfClass:[NSData class]] ? v : [NSData data];
hvl_t hv; hv.len = d.length;
hv.p = d.length ? (void *)d.bytes : NULL;   // cast away const; HDF5 read-only on write
if (d.length) [retained addObject:d];        // keep alive until after writeCompoundDataset
memcpy(base + off, &hv, sizeof(hvl_t));
```
Drop `vlBytesAllocs` and its post-write `free` loop entirely. The existing `retained` array
(already used to keep VLString NSStrings alive, `:617,:647,:679`) is cleared AFTER
`writeCompoundDataset` (`:671→:679`), which spans the H5Dwrite — correct lifetime.

### B. Hoist per-field metadata out of the inner loop
Before the row loop, precompute C arrays once: `size_t fieldOff[nFields]`,
`TTIOCompoundFieldKind fieldKind[nFields]`, and `__unsafe_unretained NSString *fieldName[nFields]`
(borrowed refs; `fields` stays alive for the loop). The inner loop uses these instead of
`[offsets[i] unsignedIntegerValue]` / `fields[i].kind` / `fields[i].name` per row. The
`row[fieldName[i]]` dictionary lookup stays (the NSDictionary row interface is unchanged — that
is the callers' concern, out of scope here).

### C. Leave everything else identical
VLString path unchanged (already retains + points at `[s UTF8String]`, no malloc). Non-HDF5
provider path (`:573-581`) unchanged. Primitive memcpy into `base+off` unchanged. Compound type
build unchanged. Output bytes identical.

## Why byte-identical
- VL write: HDF5 reads `hv.len` bytes from `hv.p` and writes them to the same global-heap VL
  layout regardless of whether `hv.p` was a malloc'd copy or the NSData's own buffer. Same len,
  same bytes → identical on-disk.
- Primitives/strings/schema/offsets unchanged.
- The ONLY behavioral change is memory provenance + when temporaries are freed — not any byte
  written.

## Invariants & verification
- Only `objc/Source/Dataset/TTIOCompoundIO.m` changes; no header/API/wire change; no caller change.
- **Byte-identity (critical):** snapshot a small compound-bearing file (e.g. a per-AU-encrypted
  `.tio` and a genomic `.tio` with mate_info) BEFORE (main) and AFTER; the compound dataset bytes
  must be identical (use `h5dump`/`H5Dread` compare, or full-file cmp where reproducible). A
  random per-AU IV makes encryption files non-reproducible run-to-run — for those, verify via
  decode/round-trip + cross-SDK conformance instead of raw cmp; use a deterministic compound
  fixture (e.g. mate_info / genomic positions, no random IV) for the raw byte cmp.
- Full ObjC suite: `cd objc && ./build.sh check` — ALL green (per-AU encryption, genomic,
  mate_info, M43 cross-backend compound byte-identity, compound read/write round-trip).
- Cross-SDK conformance: ObjC-written compound/encrypted files decode in Python/Java (per-AU
  conformance + transport + mate_info conformance suites).
- **VL lifetime / memory safety:** confirm no use-after-free (NSData alive through H5Dwrite),
  no double-free (vlBytesAllocs removed), and no leak. Run under ASan if available; at minimum
  the autorelease/lifetime reasoning must be explicit.
- Perf: re-measure (force-rebuild libTTIO first — the harness only rebuilds when missing; and
  `chmod +x tools/perf/*.sh`): `encryption.encrypt` should drop toward Java's ~270ms; spot-check
  `codecs.genomic.mate_info_v2_encode` and `genomic.write` for improvement, no regression.

## Success criteria
`writeGeneric` does zero-copy VL writes + hoisted per-field metadata; byte-identical output
proven (deterministic fixture cmp + conformance); ObjC suite green; measured improvement on
`encryption.encrypt` (and other compound writes). One PR (1 commit).

## Out of scope (further follow-ups if numbers still trail Java)
- Copy #1: `TTIOChannelSegment` `[copy]`→retain (encryption-specific, `TTIOPerAUEncryption.m`).
- Copy #2: replace the per-row `NSDictionary` interface with typed/columnar input (touches all
  callers — larger change).
- Java `.tio` bloat (#251), Java `Cipher.getInstance` hoist, Python Cython parity flags.
