# Codec Registry — Objective-C Port — Design

**Date:** 2026-06-03
**Status:** Approved (brainstorm), pending implementation plan
**Scope owner:** genomic/codec subsystem, ObjC SDK
**Origin:** Third and final SDK parity port of the codec registry (Python PR #209,
Java PR #210). Completes the 3-language parity.

## Background

Python and Java unified genomic codec dispatch behind a `Codec` registry. ObjC
still has the pre-registry shape: a byte-channel `switch` plus five bespoke
per-channel decode methods, a byte-stream encode `switch` duplicated across two
near-identical writer bodies, and **no codec-metadata abstraction** (an inlined
`_TTIO_V18_UseRefDiffV2` eligibility predicate stands in).

ObjC dispatch surface (verified):

- **Decode** (`objc/Source/Genomics/TTIOGenomicRun.m`): byte-channel
  `-byteChannelSliceNamed:offset:count:error:` with `switch (codec_id)` at
  `:346` (6 arms: 4/5 `TTIORansDecode`, 6 `TTIOBasePackDecode`,
  7 `TTIOQualityDecode`, 9 reject, 11 `TTIODeltaRansDecode`, 12
  `-_ttio_m94z_decodeFqzcompNx16Z:`, default reject); bespoke side-paths:
  `-_decodeRefDiffV2Sequences:error:` (`:956`, gated by `-_sequencesIsRefDiffV2`
  `:912`), `-_ttio_m94z_decodeFqzcompNx16Z:error:` (`:406`),
  `-readNameAtIndex:error:` (`:443`, name_tok at `:528`),
  `-cigarAtIndex:error:` (`:618`, rANS length-prefix at `:660`),
  `-_decodeMateInfoInlineV2:error:` (`:1112`, gated by `-_mateInfoIsInlineV2`).
  Per-read assembly `-readAtIndex:error:` (`:1303`).
- **Encode** (`objc/Source/Dataset/TTIOSpectralDataset.m`): byte-stream switch in
  `_TTIO_M86_EncodeWithCodec(raw, codec)` (`:403`, 4 arms), driven by
  `_TTIO_M86_WriteByteChannel` (`:551`) / `…Storage` (`:602`); writer
  side-paths `_TTIO_V18_WriteRefDiffV2SequencesHDF5` (`:1784`) / `…Storage`
  (`:1847`), `_TTIO_M94Z_WriteQualitiesFqzcompNx16Z` (`:1927`), name_tok inline
  (`:2180`/`:2666`), mate_info (`:2226`/`:2698`). The dispatch lives in **two
  near-identical bodies** — the HDF5 fast-path (`:2071-2238`) and the
  storage-protocol path (`:2483-2714`).
- **Embed predicate**: `_TTIO_V18_UseRefDiffV2(run)` (`:1749`) — a *single*
  function (native-available + `referenceChromSeqs != nil` + all reads mapped),
  consumed at the two sequences dispatch sites (`:2101`, `:2569`). Reference
  embedding itself is a separate `BOOL embedReference` property.
- **`TTIOCompression`** (`objc/Source/ValueClasses/TTIOEnums.h:59-74`) is an
  `NS_ENUM` with **explicit** values = wire ids: RansOrder0=4, RansOrder1=5,
  BasePack=6, QualityBinned=7, DeltaRansOrder0=11, FqzcompNx16Z=12,
  MateInlineV2=13, RefDiffV2=14, NameTokenizedV2=15 (8/9/10 reserved).
- **`DELTA_RANS_ORDER0` IS dispatched** in ObjC decode (case 11) — unlike Java
  where it was unwired. So registering it is a true wiring, not just additive.
- **Build:** GNUstep + clang with **`-fobjc-arc`** (`objc/GNUmakefile.preamble:96`)
  — ARC is on; no manual memory management.
- **Native gating:** compile-time `#if __has_include(<ttio_rans.h>)` →
  `TTIO_HAS_NATIVE_RANS`; each smart codec exposes `+nativeAvailable` and
  returns nil+error when absent. rANS/base_pack/quality/delta are pure ObjC (no
  native lib).

## Goals

1. Port the codec registry to ObjC with full structural parity: a `TTIOCodec`
   `@protocol`, a `TTIOCodecContext` value object, closed unions as abstract
   class clusters (`TTIODecodedChannel`/`TTIOEncodedChannel`/`TTIOChannelPayload`),
   and a `TTIOCodecRegistry` singleton keyed by `TTIOCompression`. Collapse the
   decode switch + five side-paths and route **both** encode bodies through the
   registry.
2. Register all 9 real codec ids.
3. Add two codec flags — `isContextAware` and `needsEmbeddedReference`
   (REF_DIFF_V2 only) — for cross-language parity.

## Non-goals / hard invariants

- **No wire/on-disk format change.** Wire id = the explicit `TTIOCompression`
  value, unchanged; codec byte streams + group layouts byte-identical. The free
  C codec functions + smart-codec class methods are reused verbatim behind
  adapters.
- **No embed-behavior change.** `_TTIO_V18_UseRefDiffV2` stays as the default-path
  eligibility gate (it is already a single function — no dedup needed); only the
  registry `needsEmbeddedReference` flag is added.
- **Do NOT fully merge the two encode bodies.** Route both through the registry
  (unifying codec selection); merging the ~150-line HDF5/storage twins is a
  separate refactor, out of scope (bounded risk).
- Out of scope: `indicesForRegion` vectorization; HDF5-native filters.

## Architecture

New group `objc/Source/Codecs/Registry/` (ARC; `TTIO`-prefixed classes).

### Closed unions — abstract class clusters

- **`TTIODecodedChannel`** (abstract) → `TTIODecodedBytes` (`NSData *data`),
  `TTIODecodedStringList` (`NSArray<NSString*> *names`), `TTIODecodedMateInfo`
  (`NSArray<NSNumber*> *mateChromIds`, `NSData *matePositions`,
  `NSData *templateLengths` — matching the shapes `TTIOMateInfoV2` out-params
  produce; the plan confirms exact types).
- **`TTIOEncodedChannel`** (abstract) → `TTIOEncodedDatasetBytes`
  (`NSData *bytes`), `TTIOEncodedGroupLayout`
  (`NSDictionary<NSString*,NSData*> *children`, `NSDictionary *attrs`).
- **`TTIOChannelPayload`** (abstract) → `TTIOBytesPayload` (`NSData *bytes`),
  `TTIOGroupPayload` (`id<TTIOStorageGroup> group`).

Consumers extract via `isKindOfClass:` (no `kind` enum to keep in sync). Each
concrete class has a designated initializer + a convenience `+with…` factory.

### `TTIOCodecContext` — fat immutable value object

Carries every field any codec needs (the smart codecs are context-heavy):
`readLengths`, `revcompFlags` (as `NSData` of the codec's expected element type,
or `int[]`-wrapping — plan confirms what `+[TTIOFqzcompNx16Z]` expects),
`elementSize`, `readCount`, `positions` (int64-LE `NSData`),
`cigarsProvider` (lazy `NSArray<NSString*> *(^)(void)` block — the ObjC thunk),
`totalBases`, `chromosomes`, `ownChromIds`, `ownPositions`, `nRecords`,
`referenceResolver` (`TTIOReferenceResolver *`); encode-only `offsets`,
`reference`, `referenceMd5`, `referenceUri`, `readsPerSlice`. `+emptyContext`
returns an all-nil instance; a builder or a designated init populates fields.

### `TTIOCodec` protocol + `TTIOCodecRegistry`

```objc
@protocol TTIOCodec <NSObject>
- (TTIOCompression)codecId;
- (BOOL)isContextAware;
- (BOOL)needsEmbeddedReference;
- (nullable TTIODecodedChannel *)decode:(TTIOChannelPayload *)payload
                                context:(TTIOCodecContext *)ctx
                                  error:(NSError **)error;
- (nullable TTIOEncodedChannel *)encode:(TTIODecodedChannel *)value
                                context:(TTIOCodecContext *)ctx
                                  error:(NSError **)error;
@end
```

`TTIOCodecRegistry` holds `NSDictionary<NSNumber*, id<TTIOCodec>>` keyed by
`@(TTIOCompression…)`, initialized via **`pthread_once`** (per GNUstep+Linux
guidance — not `dispatch_once`). Exposes
`+ (nullable id<TTIOCodec>)codecForId:(TTIOCompression)cid`. Each entry is a
thin adapter object wrapping the existing free C function (`TTIORansEncode`/
`TTIORansDecode`, `TTIOBasePackEncode`, `TTIOQualityEncode`, `TTIODeltaRansEncode`)
or class method (`+[TTIORefDiffV2 …]`, `+[TTIOFqzcompNx16Z …]`,
`+[TTIOMateInfoV2 …]`, `+[TTIONameTokenizerV2 …]`), preserving each codec's
`nativeAvailable` guard + `NSError` propagation.

Flags: REF_DIFF_V2 `isContextAware=YES needsEmbeddedReference=YES`;
FQZCOMP_NX16_Z + MATE_INLINE_V2 `isContextAware=YES needsEmbeddedReference=NO`;
all others `NO/NO`. `codecForId:` returns nil for unregistered/reserved ids
(membership-safe; callers null-check — the lesson from the Python/Java ports).

## Dispatch collapse

**Decode (`TTIOGenomicRun.m`):** add cached `-_codecContext` (built from `_index`
+ `TTIOReferenceResolver`; encapsulates the `flags & 16` revcomp derivation and
the encounter-order `ownChromIds` map from `_decodeMateInfoInlineV2`). Route:
- byte-channel switch → `[TTIOCodecRegistry codecForId:(TTIOCompression)codec_id]`,
  `TTIOBytesPayload`, dispatch on the `TTIODecodedBytes` result.
- ref_diff group special-case → `TTIOGroupPayload` decode.
- read_names → name_tok decode → `TTIODecodedStringList`.
- mate_info → `TTIODecodedMateInfo`.
- cigars → route ONLY the inner rANS through the registry; length-prefix framing
  stays in `cigarAtIndex`.
Per-channel caches preserved.

**Encode (`TTIOSpectralDataset.m`):** route **both** encode bodies (HDF5 + storage)
through the registry. `TTIOEncodedDatasetBytes` → write the flat dataset +
`@compression`; `TTIOEncodedGroupLayout` → create the `refdiff_v2` group + child
+ attrs. The two bodies remain two call sites (not merged).

**Embed predicate:** `_TTIO_V18_UseRefDiffV2` is unchanged (single function,
default-path eligibility). Only `needsEmbeddedReference` is added to the registry
for parity.

## Testing

- New `objc/Tests/TestCodecRegistry.m` using GNUstep `Testing.h` `PASS(...)`
  macros + `START_SET`/`END_SET`, with a `testCodecRegistry()` C function
  registered in `objc/Tests/TTIOTestRunner.m`. Covers: union `isKindOfClass:`
  extraction; per-codec round-trip through the registry asserting byte-equality
  (`isEqualToData:`); QUALITY idempotency (lossy); completeness (all 9 ids);
  two-flag parity (`needsEmbeddedReference` only REF_DIFF_V2; `isContextAware`
  ⊇ {REF_DIFF, FQZCOMP, MATE}); `codecForId:` returns nil for unregistered ids;
  native-availability surfaced.
- Existing gates must stay green: `TestM86GenomicCodecWiring`,
  `TestRefDiffV2Dispatch`, `TestMateInfoV2Dispatch`, `TestNameTokenizedV2Dispatch`,
  the per-codec unit tests, and the cross-language byte-equality `Fixtures/*.bin`
  fences. Run via `objc/build.sh check` (which post-parses GNUstep Testing output
  and fails on any reported failure).

## Delivery

Single ObjC-only PR. Build/test in WSL: `objc/build.sh check` (native
`libttio_rans` present). Push from Windows git. CI's cross-language parity job
(GENOMIC_RUNS accessor across java/python/objc) is the real gate. This completes
the 3-SDK codec-registry parity.

## File structure

| File | Change | Responsibility |
|---|---|---|
| `Codecs/Registry/TTIODecodedChannel.{h,m}` | Create | decode union cluster |
| `Codecs/Registry/TTIOEncodedChannel.{h,m}` | Create | encode union cluster |
| `Codecs/Registry/TTIOChannelPayload.{h,m}` | Create | payload union cluster |
| `Codecs/Registry/TTIOCodecContext.{h,m}` | Create | context value object |
| `Codecs/Registry/TTIOCodec.h` | Create | codec protocol |
| `Codecs/Registry/TTIOCodecRegistry.{h,m}` | Create | registry singleton + adapters |
| `Genomics/TTIOGenomicRun.m` | Modify | `-_codecContext` + route decode |
| `Dataset/TTIOSpectralDataset.m` | Modify | route both encode bodies |
| `Tests/TestCodecRegistry.m` | Create | registry tests |
| `Tests/TTIOTestRunner.m` | Modify | register the test |
| `objc/Source/GNUmakefile` + `Tests/GNUmakefile` | Modify | add new sources/test to the build |
| `CHANGELOG.md` | Modify | `[Unreleased]` entry |

## Risks

- **GNUmakefile registration:** new `.m` sources must be added to the ObjC
  library GNUmakefile and the test to the Tests GNUmakefile (GNUstep is not
  auto-discovery). Easy to forget → link errors.
- **ref_diff is the hard case** (group layout + reference resolution from blob
  header + single-chromosome). Its decode adapter is a faithful relocation of
  `-_decodeRefDiffV2Sequences`; verify the `+[TTIORefDiffV2 …]` out-param
  signatures + `TTIOReferenceResolver` API before relying on them.
- **mate_info `ownChromIds` encounter-order** must mirror
  `-_decodeMateInfoInlineV2` exactly — byte-equality contract.
- **Two encode bodies:** both must route identically; a divergence between the
  HDF5 and storage paths would be a real bug. The `Fixtures/*.bin` + M86
  round-trip tests are the fence.
- **`codecForId:` nil** for reserved/unregistered ids — callers null-check.

## Follow-on

None — this is the final SDK. After merge, all three SDKs share the registry
architecture; a subsequent release can be cut bundling the three ports.
