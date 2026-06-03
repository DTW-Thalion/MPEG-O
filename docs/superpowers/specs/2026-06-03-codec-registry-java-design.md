# Codec Registry — Java Port — Design

**Date:** 2026-06-03
**Status:** Approved (brainstorm), pending implementation plan
**Scope owner:** genomic/codec subsystem, Java SDK
**Origin:** Java parity port of the Python codec registry (PR #209,
`docs/superpowers/specs/2026-06-02-codec-registry-design.md`). One of two
follow-on ports (ObjC is the other).

## Background

The Python SDK unified its genomic codec dispatch behind a `Codec` registry
(PR #209). Java still has the pre-registry shape the Python port removed: a
central decode ladder plus four bespoke side-paths, an encode `switch` plus
dedicated writer methods, and **no codec-metadata abstraction at all** (the
reference-embed predicate is an inlined boolean duplicated at two sites).

Java dispatch surface (verified):

- **Decode** (`genomics/GenomicRun.java`): byte-channel ladder
  `byteChannelSlice:436-466` (5 arms: RANS_ORDER0/1, BASE_PACK, QUALITY_BINNED,
  FQZCOMP_NX16_Z + throw); bespoke side-paths for sequences/ref_diff
  (`decodeRefDiffV2Sequences:489-568`, probed at `:417`), cigars
  (`cigarAt:662-705`), read_names (`readNameAt:601-645`), mate_info
  (`mateChromAt/...` + `_decodeMateV2:803-853`).
- **Encode** (`SpectralDataset.java`): generic `writeByteChannelWithCodec:2220-2232`
  (4 arms) + writer methods `writeSequencesRefDiff:2050`,
  `writeQualitiesFqzcompNx16Z:2168`, name_tok inline `:1564-1610`,
  `writeMateInfoV2:1716`; override-whitelist `allowedCodecsByChannel:1263-1278`.
- **Reference-embed predicate**: an inlined `useRefDiffPath` boolean duplicated
  at `embedReferencesForRuns:1936-1939` and `writeGenomicRunSubtree:1447-1450`.
- **`Compression`** (`Enums.java:85-149`) is a plain Java `enum` whose **wire id
  is `ordinal()`** (`codecIdFor → codec.ordinal()`); `_RESERVED_8/9/10` are
  `@Deprecated` placeholders kept solely to preserve later ordinals
  (DELTA_RANS_ORDER0=11, FQZCOMP_NX16_Z=12, MATE_INLINE_V2=13, REF_DIFF_V2=14,
  NAME_TOKENIZED_V2=15; RANS_ORDER0=4, RANS_ORDER1=5, BASE_PACK=6,
  QUALITY_BINNED=7).
- **`DELTA_RANS_ORDER0` is currently unwired** — `DeltaRans.encode/decode` exist
  and are unit-tested but no dispatch path invokes them (only a sentinel in the
  FQZ-candidate gate at `:1485`).
- **JDK 22** (`pom.xml` `maven.compiler.release=22`) — sealed interfaces,
  records, and pattern-matching `switch` are GA.

## Goals

1. Port the Python codec registry to Java with full structural parity: a `Codec`
   interface, a `CodecContext` value object, closed `DecodedChannel` /
   `EncodedChannel` / `ChannelPayload` unions, and a `CodecRegistry` keyed by
   `Compression`. Collapse the decode ladder + four side-paths and the encode
   `switch` + writer methods to one registry lookup per direction.
2. Register **all 9 real codec ids including `DELTA_RANS_ORDER0`** (additive —
   nothing dispatches it today, so no behavior change; satisfies the
   completeness guard and matches Python).
3. Add two codec flags — `isContextAware` (needs `CodecContext`) and
   `needsEmbeddedReference` (reference-embed predicate, true only for
   REF_DIFF_V2) — and **dedup the duplicated `useRefDiffPath` boolean** into one
   helper, preserving the embed decision byte-for-byte.

## Non-goals / hard invariants

- **No wire/on-disk format change.** Wire id = `ordinal()` unchanged; codec
  byte streams + group layouts byte-identical. Codec *bodies* reused verbatim
  behind thin adapters.
- **No embed-behavior change.** The reference-embed decision must be byte-identical
  (this is the subtle trap that caused the Python T6 BLOCK; Java's predicate is
  structured differently — default-path-based, not override-based — so the dedup
  is a careful extraction, not a blind mirror).
- Out of scope: `GenomicIndex.indicesForRegion` vectorization (separate); the
  ObjC port (separate follow-on); the HDF5-native filters (ZLIB/LZ4/NUMPRESS).

## Architecture

New package `java/src/main/java/global/thalion/ttio/codecs/registry/`.

### Closed unions — `sealed interface` + `record` (the lead decision)

```java
public sealed interface DecodedChannel {
    record Bytes(byte[] data) implements DecodedChannel {}
    record StrList(List<String> names) implements DecodedChannel {}
    record MateInfo(int[] mateChromIds, long[] matePositions, int[] templateLengths)
        implements DecodedChannel {}
}

public sealed interface EncodedChannel {
    record DatasetBytes(byte[] bytes) implements EncodedChannel {}
    record GroupLayout(Map<String, byte[]> children, Map<String, Object> attrs)
        implements EncodedChannel {}
}

public sealed interface ChannelPayload {
    record BytesPayload(byte[] bytes) implements ChannelPayload {}
    record GroupPayload(StorageGroup group) implements ChannelPayload {}
}
```

Consumers use pattern-matching `switch` (`case DecodedChannel.Bytes(var b) -> ...`).
`MateInfo` mirrors `MateInfoV2.Triple`; the variant set is closed (3 decode + 2
encode + 2 payload), matching Python's union shapes exactly so the parity holds.

### `CodecContext` — record with a Builder

All fields nullable/optional (boxed where primitive). 17 fields → a `Builder`
avoids a positional megaconstructor.

- Decode/shared: `int[] readLengths`, `int[] revcompFlags`, `Integer elementSize`,
  `Integer readCount`, `long[] positions`, `Supplier<String[]> cigarsProvider`
  (lazy — mirrors Python's thunk), `Long totalBases`, `String[] chromosomes`,
  `short[] ownChromIds`, `long[] ownPositions`, `Integer nRecords`,
  `ReferenceResolver referenceResolver`.
- Encode-only (ref_diff): `long[] offsets`, `byte[] reference`,
  `byte[] referenceMd5`, `String referenceUri`, `Integer readsPerSlice`.
- `CodecContext.empty()` → all-null; `CodecContext.builder()...build()`.

### `Codec` interface + `CodecRegistry`

```java
public interface Codec {
    Compression id();
    boolean isContextAware();
    boolean needsEmbeddedReference();
    DecodedChannel decode(ChannelPayload payload, CodecContext ctx);
    EncodedChannel encode(DecodedChannel value, CodecContext ctx);
}
```

`CodecRegistry.CODEC_REGISTRY` is an `EnumMap<Compression, Codec>` (keyed by the
enum so the `_RESERVED_8/9/10` ordinal gaps stay invisible). Java codecs are
`static`-only, so each entry is a thin instance adapter wrapping the static
class. Flags:

| Codec | id | isContextAware | needsEmbeddedReference |
|---|---|---|---|
| RANS_ORDER0/1, BASE_PACK, QUALITY_BINNED, DELTA_RANS_ORDER0, NAME_TOKENIZED_V2 | 4/5/6/7/11/15 | false | false |
| FQZCOMP_NX16_Z | 12 | true | false |
| MATE_INLINE_V2 | 13 | true | false |
| REF_DIFF_V2 | 14 | true | **true** |

Each adapter preserves its codec's `isAvailable()` native-lib guard and error
message (cross-language tests assert these). The registry is consulted via
`CODEC_REGISTRY.get(...)` (membership-safe — returns null for
unregistered/reserved ids; callers handle null, never an unguarded throw).

## Dispatch collapse

**Decode (`GenomicRun.java`):** add cached `codecContext()` (built from the
`GenomicIndex` + `runGroup` + lazy `allCigars` supplier; encapsulates the
`flags & 16` revcomp derivation and the encounter-order `short[] ownChromIds`
map). Route:
- byte-channel ladder → `CODEC_REGISTRY.get(Compression.values()[codecId])`,
  pattern-`switch` the `DecodedChannel.Bytes`.
- ref_diff group special-case → registry `GroupPayload` decode.
- read_names → registry `NAME_TOKENIZED_V2` decode → `StrList`.
- mate_info → registry `MATE_INLINE_V2` decode → `MateInfo`.
- cigars (rANS + length-prefix framing) → route the inner rANS through the
  registry while the length-prefix wrapping stays in the channel reader, matching
  the Python port's cigars treatment (verified during planning).
Per-channel caches preserved; the registry replaces only selection.

**Encode (`SpectralDataset.java`):** route `writeByteChannelWithCodec` + the
writer methods through the registry with an encode-time `CodecContext`.
`DatasetBytes` → write the flat dataset + `@compression`; `GroupLayout` (ref_diff)
→ create the `sequences` group + `refdiff_v2` child + attrs.

**Embed predicate:** add `needsEmbeddedReference` to the registry; extract the
duplicated `useRefDiffPath` boolean (`:1936-1939`, `:1447-1450`) into one private
helper. The embed decision must be byte-identical (guarded by the embed
byte-equality tests); the registry flag is wired into the override-based portion
only if it provably preserves behavior, otherwise it stays available + tested
without altering the decision.

## Testing

- New `src/test/java/.../codecs/registry/CodecRegistryTest.java` (JUnit 5,
  mirroring `test_codec_registry.py`): union pattern/accessor tests; per-codec
  round-trip through the registry with `assertArrayEquals` byte-equality; QUALITY
  idempotency (lossy); completeness guard (all 9 ids); two-flag parity
  (`needsEmbeddedReference == {REF_DIFF_V2}`; `isContextAware ⊇ {REF_DIFF,
  FQZCOMP, MATE}`); embed-predicate safety (unregistered `Compression` → no
  exception). Follows the `M86CodecWiringTest` write-read-assertArrayEquals style.
- Existing gates must stay green: `M86CodecWiringTest`, `RefDiffV2DispatchTest`,
  `MateInfoV2DispatchTest`, `NameTokenizedV2DispatchTest`, the per-codec unit
  tests, and the cross-language byte-equality matrix
  (`Tests/cross_lang/transport_v0_11/accessor_matrix_xlang.sh`, GENOMIC_RUNS
  accessor).

## Delivery

Single Java-only PR. Build/test locally with `JAVA_HOME=~/jdk25 mvn -q test` in
`java/` (JDK 22+ required — the class-file-66 jars need a ≥22 runtime; running
mvn under jdk25 avoids the Java-21 mismatch seen elsewhere). Push from Windows
git; CI's cross-language parity job is the real gate.

## File structure

| File | Change | Responsibility |
|---|---|---|
| `codecs/registry/DecodedChannel.java` | Create | decode union |
| `codecs/registry/EncodedChannel.java` | Create | encode union |
| `codecs/registry/ChannelPayload.java` | Create | payload union |
| `codecs/registry/CodecContext.java` | Create | context record + Builder |
| `codecs/registry/Codec.java` | Create | codec interface |
| `codecs/registry/CodecRegistry.java` | Create | registry + adapters |
| `genomics/GenomicRun.java` | Modify | `codecContext()` + route decode |
| `SpectralDataset.java` | Modify | route encode + dedup embed predicate |
| `src/test/java/.../codecs/registry/CodecRegistryTest.java` | Create | registry tests |
| `CHANGELOG.md` | Modify | `[Unreleased]` entry |

## Risks

- **Embed-decision equivalence** (highest): Java's predicate differs structurally
  from Python's; the dedup must be byte-identical. Mitigation: extract-only dedup
  + embed byte-equality tests + final review (mirrors the Python T6 lesson).
- **cigars length-prefix framing** does not map to a clean registry codec; route
  the inner rANS only, keep framing in the reader.
- **`Compression.values()[codecId]`** for unregistered/reserved ids returns a
  valid enum constant absent from the registry → `CODEC_REGISTRY.get(...)` is
  null; callers must handle null (membership-safe), never an unguarded subscript.
- **Native availability**: adapters must preserve each codec's `isAvailable()`
  guard + error message.

## Follow-on

ObjC port (the third parity SDK) — its own spec/plan, reusing this interface
shape (`@protocol` + class clusters for the unions, `NSDictionary` registry).
