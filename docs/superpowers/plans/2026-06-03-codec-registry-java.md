# Codec Registry — Java Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Python codec registry (PR #209) to Java: a `Codec` interface + `EnumMap<Compression,Codec>` registry + sealed-union value types, collapsing the decode ladder + 4 side-paths and the encode switch + writer methods to one registry lookup per direction, with **zero wire/format change and zero embed-behavior change**.

**Architecture:** New package `global.thalion.ttio.codecs.registry` with `sealed interface`+`record` unions (`DecodedChannel`/`EncodedChannel`/`ChannelPayload`), a `CodecContext` record+Builder, a `Codec` interface, and `CodecRegistry` (thin instance adapters over the static codec classes). `GenomicRun` decode + `SpectralDataset` encode route through it; the duplicated `useRefDiffPath` embed predicate is deduped.

**Tech Stack:** Java 22 (sealed interfaces, records, pattern-matching switch), JUnit 5, Maven. Build/test in WSL: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -Dtest=<T> test'`. Push from Windows git. Spec: `docs/superpowers/specs/2026-06-03-codec-registry-java-design.md`.

**Branch:** `feat/codec-registry-java` (created off `main`; spec committed on it).

**Invariant (every task):** existing Java codec/genomic tests + the cross-language byte-equality matrix stay green. Codec wire id = `Compression.ordinal()` and all codec byte streams unchanged.

---

## Reference facts (verified)

- Codec package `global.thalion.ttio.codecs`; new package `…codecs.registry`.
- `global.thalion.ttio.Enums.Compression` — wire id = `ordinal()`: RANS_ORDER0=4, RANS_ORDER1=5, BASE_PACK=6, QUALITY_BINNED=7, DELTA_RANS_ORDER0=11, FQZCOMP_NX16_Z=12, MATE_INLINE_V2=13, REF_DIFF_V2=14, NAME_TOKENIZED_V2=15. `_RESERVED_8/9/10` are valid but unregistered.
- Codec static methods: `Rans.encode(byte[],int order)`/`decode(byte[])`; `BasePack.encode(byte[])`/`decode(byte[])`; `Quality.encode(byte[])`/`decode(byte[])`; `DeltaRans.encode(byte[],int elementSize)`/`decode(byte[])`; `FqzcompNx16Z.encode(byte[] q,int[] readLengths,int[] revcompFlags)` + `DecodeResult decode(byte[],int[] revcompFlags)` with `dr.qualities()`/`dr.readLengths()`; `NameTokenizerV2.encode(List<String>)`/`List<String> decode(byte[])`; `MateInfoV2.encode(int[] mateChromIds,long[] matePositions,int[] templateLengths,short[] ownChromIds,long[] ownPositions)` + `Triple decode(byte[],short[] ownChromIds,long[] ownPositions,int nRecords)` with `.mateChromIds()/.matePositions()/.templateLengths()`; `RefDiffV2.encode(byte[] sequences,long[] offsets,long[] positions,String[] cigarStrings,byte[] reference,byte[] referenceMd5,String referenceUri,int readsPerSlice)` + `Pair decode(byte[],long[] positions,String[] cigarStrings,byte[] reference,int nReads,long totalBases)` with `.sequences()/.offsets()`, plus `BlobHeader parseBlobHeader(byte[])` (`.referenceUri()`,`.referenceMd5()`) and `boolean isAvailable()`.
- `GenomicIndex`: `count()`, `offsetAt(i)`, `lengthAt(i)`, `positionAt(i)`, `flagsAt(i)`, `chromosomeAt(i)`.
- `global.thalion.ttio.providers.{StorageGroup,StorageDataset}`; `ds.readSlice(off,count)->Object` (cast `byte[]`), `ds.shape()[0]`, `sc.createDataset(name,Precision,len,chunk,Compression,lvl)`, `ds.writeAll(byte[])`, `ds.setAttribute("compression",int)`, `sc.openGroup(name)`/`openDataset(name)`.
- `genomics/GenomicRun.java`: decode ladder `byteChannelSlice:436-466`; cache field `decodedByteChannels` (Map); side-paths `decodeRefDiffV2Sequences`, `cigarAt`, `readNameAt`, `_decodeMateV2`.
- `SpectralDataset.java`: encode switch `writeByteChannelWithCodec:2210-2255`; `codecIdFor(codec)=ordinal()`; embed predicate `useRefDiffPath` at `:1936-1939` and `:1447-1450`.
- `ReferenceResolver` at `global.thalion.ttio.genomics.ReferenceResolver`; obtained from the HDF5-backed run group (see `decodeRefDiffV2Sequences`).

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `codecs/registry/DecodedChannel.java` | Create | decode union (Bytes/StrList/MateInfo) |
| `codecs/registry/EncodedChannel.java` | Create | encode union (DatasetBytes/GroupLayout) |
| `codecs/registry/ChannelPayload.java` | Create | payload union (BytesPayload/GroupPayload) |
| `codecs/registry/CodecContext.java` | Create | context record + Builder |
| `codecs/registry/Codec.java` | Create | codec interface |
| `codecs/registry/CodecRegistry.java` | Create | registry + 9 adapters |
| `genomics/GenomicRun.java` | Modify | `codecContext()` + route decode |
| `SpectralDataset.java` | Modify | route encode + dedup embed predicate |
| `src/test/java/.../codecs/registry/CodecRegistryTest.java` | Create | registry tests |
| `CHANGELOG.md` | Modify | `[Unreleased]` entry |

All `src/main` files under `java/src/main/java/global/thalion/ttio/`; tests under `java/src/test/java/global/thalion/ttio/`.

---

## Task 1: Sealed-union value types + CodecContext

**Files:** Create `codecs/registry/{DecodedChannel,EncodedChannel,ChannelPayload,CodecContext}.java`; create `src/test/java/global/thalion/ttio/codecs/registry/CodecRegistryTest.java`.

- [ ] **Step 1: Write the failing test** — create `CodecRegistryTest.java`:

```java
package global.thalion.ttio.codecs.registry;

import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class CodecRegistryTest {

    @Test
    void decodedChannelBytesVariant() {
        DecodedChannel d = new DecodedChannel.Bytes(new byte[]{1, 2, 3});
        assertInstanceOf(DecodedChannel.Bytes.class, d);
        assertArrayEquals(new byte[]{1, 2, 3}, ((DecodedChannel.Bytes) d).data());
    }

    @Test
    void decodedChannelStrListVariant() {
        DecodedChannel d = new DecodedChannel.StrList(List.of("r1", "r2"));
        assertEquals(List.of("r1", "r2"), ((DecodedChannel.StrList) d).names());
    }

    @Test
    void encodedChannelVariants() {
        EncodedChannel a = new EncodedChannel.DatasetBytes(new byte[]{9});
        assertArrayEquals(new byte[]{9}, ((EncodedChannel.DatasetBytes) a).bytes());
        EncodedChannel b = new EncodedChannel.GroupLayout(
            Map.of("refdiff_v2", new byte[]{7}), Map.of());
        assertTrue(((EncodedChannel.GroupLayout) b).children().containsKey("refdiff_v2"));
    }

    @Test
    void channelPayloadBytesVariant() {
        ChannelPayload p = new ChannelPayload.BytesPayload(new byte[]{4});
        assertArrayEquals(new byte[]{4}, ((ChannelPayload.BytesPayload) p).bytes());
    }

    @Test
    void codecContextEmptyIsAllNull() {
        CodecContext ctx = CodecContext.empty();
        assertNull(ctx.readLengths());
        assertNull(ctx.elementSize());
        assertNull(ctx.referenceResolver());
        assertNull(ctx.cigarsProvider());
    }

    @Test
    void codecContextBuilderSetsFields() {
        CodecContext ctx = CodecContext.builder()
            .elementSize(4).readCount(10).build();
        assertEquals(4, ctx.elementSize());
        assertEquals(10, ctx.readCount());
        assertNull(ctx.positions());
    }
}
```

- [ ] **Step 2: Run to verify FAIL**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -Dtest=CodecRegistryTest test 2>&1 | tail -20'`
Expected: compile failure — `package global.thalion.ttio.codecs.registry does not exist` / cannot find symbol.

- [ ] **Step 3: Create the three union files**

`codecs/registry/DecodedChannel.java`:
```java
package global.thalion.ttio.codecs.registry;

import java.util.List;

/** Closed union of a decoded channel value: bytes | str-list | mate-info.
 *  Mirrors the Python DecodedChannel; consumed via pattern-matching switch. */
public sealed interface DecodedChannel {
    record Bytes(byte[] data) implements DecodedChannel {}
    record StrList(List<String> names) implements DecodedChannel {}
    record MateInfo(int[] mateChromIds, long[] matePositions, int[] templateLengths)
        implements DecodedChannel {}
}
```

`codecs/registry/EncodedChannel.java`:
```java
package global.thalion.ttio.codecs.registry;

import java.util.Map;

/** Closed union of encode output: a flat dataset blob or a group layout (ref_diff). */
public sealed interface EncodedChannel {
    record DatasetBytes(byte[] bytes) implements EncodedChannel {}
    record GroupLayout(Map<String, byte[]> children, Map<String, Object> attrs)
        implements EncodedChannel {}
}
```

`codecs/registry/ChannelPayload.java`:
```java
package global.thalion.ttio.codecs.registry;

import global.thalion.ttio.providers.StorageGroup;

/** Encoded payload: either flat dataset bytes or a storage group (ref_diff). */
public sealed interface ChannelPayload {
    record BytesPayload(byte[] bytes) implements ChannelPayload {}
    record GroupPayload(StorageGroup group) implements ChannelPayload {}
}
```

- [ ] **Step 4: Create `codecs/registry/CodecContext.java`** (record + Builder)

```java
package global.thalion.ttio.codecs.registry;

import global.thalion.ttio.genomics.ReferenceResolver;
import java.util.function.Supplier;

/** Run-derived context for codecs. All fields nullable; plain codecs ignore it.
 *  Built once per GenomicRun (decode) or per channel (encode). */
public record CodecContext(
        int[] readLengths,
        int[] revcompFlags,
        Integer elementSize,
        Integer readCount,
        long[] positions,
        Supplier<String[]> cigarsProvider,
        Long totalBases,
        String[] chromosomes,
        short[] ownChromIds,
        long[] ownPositions,
        Integer nRecords,
        ReferenceResolver referenceResolver,
        // encode-only (ref_diff):
        long[] offsets,
        byte[] reference,
        byte[] referenceMd5,
        String referenceUri,
        Integer readsPerSlice) {

    public static CodecContext empty() { return builder().build(); }

    public static Builder builder() { return new Builder(); }

    public static final class Builder {
        private int[] readLengths;
        private int[] revcompFlags;
        private Integer elementSize;
        private Integer readCount;
        private long[] positions;
        private Supplier<String[]> cigarsProvider;
        private Long totalBases;
        private String[] chromosomes;
        private short[] ownChromIds;
        private long[] ownPositions;
        private Integer nRecords;
        private ReferenceResolver referenceResolver;
        private long[] offsets;
        private byte[] reference;
        private byte[] referenceMd5;
        private String referenceUri;
        private Integer readsPerSlice;

        public Builder readLengths(int[] v) { this.readLengths = v; return this; }
        public Builder revcompFlags(int[] v) { this.revcompFlags = v; return this; }
        public Builder elementSize(Integer v) { this.elementSize = v; return this; }
        public Builder readCount(Integer v) { this.readCount = v; return this; }
        public Builder positions(long[] v) { this.positions = v; return this; }
        public Builder cigarsProvider(Supplier<String[]> v) { this.cigarsProvider = v; return this; }
        public Builder totalBases(Long v) { this.totalBases = v; return this; }
        public Builder chromosomes(String[] v) { this.chromosomes = v; return this; }
        public Builder ownChromIds(short[] v) { this.ownChromIds = v; return this; }
        public Builder ownPositions(long[] v) { this.ownPositions = v; return this; }
        public Builder nRecords(Integer v) { this.nRecords = v; return this; }
        public Builder referenceResolver(ReferenceResolver v) { this.referenceResolver = v; return this; }
        public Builder offsets(long[] v) { this.offsets = v; return this; }
        public Builder reference(byte[] v) { this.reference = v; return this; }
        public Builder referenceMd5(byte[] v) { this.referenceMd5 = v; return this; }
        public Builder referenceUri(String v) { this.referenceUri = v; return this; }
        public Builder readsPerSlice(Integer v) { this.readsPerSlice = v; return this; }

        public CodecContext build() {
            return new CodecContext(readLengths, revcompFlags, elementSize, readCount,
                positions, cigarsProvider, totalBases, chromosomes, ownChromIds,
                ownPositions, nRecords, referenceResolver, offsets, reference,
                referenceMd5, referenceUri, readsPerSlice);
        }
    }
}
```

> If `ReferenceResolver`'s package differs from `global.thalion.ttio.genomics`, fix the import (grep `class ReferenceResolver`). Confirm `StorageGroup` is `global.thalion.ttio.providers.StorageGroup`.

- [ ] **Step 5: Run to verify PASS**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -Dtest=CodecRegistryTest test 2>&1 | tail -8'`
Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git -C ~/TTI-O add java/src/main/java/global/thalion/ttio/codecs/registry java/src/test/java/global/thalion/ttio/codecs/registry && git -C ~/TTI-O commit -m "feat(java-codecs): sealed-union value types + CodecContext"
```

---

## Task 2: Codec interface + registry with plain adapters

**Files:** Create `codecs/registry/{Codec,CodecRegistry}.java`; extend `CodecRegistryTest.java`.

- [ ] **Step 1: Add failing tests** — append to `CodecRegistryTest.java`:

```java
    @Test
    void plainCodecsRegisteredAndRoundTrip() {
        var ctx = CodecContext.empty();
        for (var cid : List.of(
                global.thalion.ttio.Enums.Compression.RANS_ORDER0,
                global.thalion.ttio.Enums.Compression.RANS_ORDER1,
                global.thalion.ttio.Enums.Compression.BASE_PACK)) {
            Codec codec = CodecRegistry.CODEC_REGISTRY.get(cid);
            assertNotNull(codec, "registered: " + cid);
            assertEquals(cid, codec.id());
            assertFalse(codec.isContextAware());
            byte[] data = new byte[256];
            for (int i = 0; i < 256; i++) data[i] = (byte) i;
            var enc = codec.encode(new DecodedChannel.Bytes(data), ctx);
            byte[] encBytes = ((EncodedChannel.DatasetBytes) enc).bytes();
            var dec = codec.decode(new ChannelPayload.BytesPayload(encBytes), ctx);
            assertArrayEquals(data, ((DecodedChannel.Bytes) dec).data());
        }
    }

    @Test
    void deltaRansNeedsElementSize() {
        Codec codec = CodecRegistry.CODEC_REGISTRY.get(
            global.thalion.ttio.Enums.Compression.DELTA_RANS_ORDER0);
        assertNotNull(codec);
        byte[] data = new byte[40];
        assertThrows(IllegalArgumentException.class,
            () -> codec.encode(new DecodedChannel.Bytes(data), CodecContext.empty()));
    }

    @Test
    void registryKeyMatchesId() {
        CodecRegistry.CODEC_REGISTRY.forEach((cid, codec) -> assertEquals(cid, codec.id()));
    }
```

- [ ] **Step 2: Run to verify FAIL** (cannot find `Codec` / `CodecRegistry`).
Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -Dtest=CodecRegistryTest test 2>&1 | tail -15'`

- [ ] **Step 3: Create `codecs/registry/Codec.java`**

```java
package global.thalion.ttio.codecs.registry;

import global.thalion.ttio.Enums.Compression;

/** A codec adapter: uniform decode/encode over the closed channel unions. */
public interface Codec {
    Compression id();
    boolean isContextAware();
    boolean needsEmbeddedReference();
    DecodedChannel decode(ChannelPayload payload, CodecContext ctx);
    EncodedChannel encode(DecodedChannel value, CodecContext ctx);
}
```

- [ ] **Step 4: Create `codecs/registry/CodecRegistry.java`** with the plain adapters (context-aware ones added in Task 3)

```java
package global.thalion.ttio.codecs.registry;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.codecs.BasePack;
import global.thalion.ttio.codecs.DeltaRans;
import global.thalion.ttio.codecs.Quality;
import global.thalion.ttio.codecs.Rans;
import java.util.EnumMap;
import java.util.Map;

/** Maps Compression ids to Codec adapters. Adapters wrap the existing static
 *  codec classes verbatim — no wire change. */
public final class CodecRegistry {
    private CodecRegistry() {}

    public static final Map<Compression, Codec> CODEC_REGISTRY = build();

    private static byte[] bytes(DecodedChannel v) {
        return ((DecodedChannel.Bytes) v).data();
    }
    private static byte[] payloadBytes(ChannelPayload p) {
        return ((ChannelPayload.BytesPayload) p).bytes();
    }

    static final class RansCodec implements Codec {
        private final Compression id;
        private final int order;
        RansCodec(Compression id, int order) { this.id = id; this.order = order; }
        public Compression id() { return id; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.Bytes(Rans.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            return new EncodedChannel.DatasetBytes(Rans.encode(bytes(v), order));
        }
    }

    static final class BasePackCodec implements Codec {
        public Compression id() { return Compression.BASE_PACK; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.Bytes(BasePack.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            return new EncodedChannel.DatasetBytes(BasePack.encode(bytes(v)));
        }
    }

    static final class QualityCodec implements Codec {
        public Compression id() { return Compression.QUALITY_BINNED; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.Bytes(Quality.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            return new EncodedChannel.DatasetBytes(Quality.encode(bytes(v)));
        }
    }

    static final class DeltaRansCodec implements Codec {
        public Compression id() { return Compression.DELTA_RANS_ORDER0; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.Bytes(DeltaRans.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            if (ctx.elementSize() == null) {
                throw new IllegalArgumentException(
                    "DELTA_RANS encode requires CodecContext.elementSize");
            }
            return new EncodedChannel.DatasetBytes(DeltaRans.encode(bytes(v), ctx.elementSize()));
        }
    }

    private static Map<Compression, Codec> build() {
        EnumMap<Compression, Codec> m = new EnumMap<>(Compression.class);
        m.put(Compression.RANS_ORDER0, new RansCodec(Compression.RANS_ORDER0, 0));
        m.put(Compression.RANS_ORDER1, new RansCodec(Compression.RANS_ORDER1, 1));
        m.put(Compression.BASE_PACK, new BasePackCodec());
        m.put(Compression.QUALITY_BINNED, new QualityCodec());
        m.put(Compression.DELTA_RANS_ORDER0, new DeltaRansCodec());
        return m;
    }
}
```

- [ ] **Step 5: Run to verify PASS** (plain round-trip, delta element-size, key/id match). Same mvn command. Note: the plain round-trip test deliberately excludes QUALITY_BINNED (lossy) — it is covered separately in Task 3.

- [ ] **Step 6: Commit**

```bash
git -C ~/TTI-O add java/src/main/java/global/thalion/ttio/codecs/registry/Codec.java java/src/main/java/global/thalion/ttio/codecs/registry/CodecRegistry.java java/src/test/java/global/thalion/ttio/codecs/registry/CodecRegistryTest.java && git -C ~/TTI-O commit -m "feat(java-codecs): Codec interface + registry + plain adapters"
```

---

## Task 3: Context-aware adapters

**Files:** Modify `codecs/registry/CodecRegistry.java`; extend `CodecRegistryTest.java`.

- [ ] **Step 1: Add failing tests** — append:

```java
    @Test
    void nameTokenizedRoundTrip() {
        Codec codec = CodecRegistry.CODEC_REGISTRY.get(
            global.thalion.ttio.Enums.Compression.NAME_TOKENIZED_V2);
        assertNotNull(codec);
        assertFalse(codec.isContextAware());
        List<String> names = new java.util.ArrayList<>();
        for (int i = 0; i < 200; i++) names.add("read" + i);
        var enc = codec.encode(new DecodedChannel.StrList(names), CodecContext.empty());
        var dec = codec.decode(new ChannelPayload.BytesPayload(
            ((EncodedChannel.DatasetBytes) enc).bytes()), CodecContext.empty());
        assertEquals(names, ((DecodedChannel.StrList) dec).names());
    }

    @Test
    void contextAwareFlags() {
        var R = CodecRegistry.CODEC_REGISTRY;
        var C = global.thalion.ttio.Enums.Compression.class;
        assertTrue(R.get(global.thalion.ttio.Enums.Compression.REF_DIFF_V2).isContextAware());
        assertTrue(R.get(global.thalion.ttio.Enums.Compression.FQZCOMP_NX16_Z).isContextAware());
        assertTrue(R.get(global.thalion.ttio.Enums.Compression.MATE_INLINE_V2).isContextAware());
        assertTrue(R.get(global.thalion.ttio.Enums.Compression.REF_DIFF_V2).needsEmbeddedReference());
        assertFalse(R.get(global.thalion.ttio.Enums.Compression.FQZCOMP_NX16_Z).needsEmbeddedReference());
    }

    @Test
    void qualityBinnedRegisteredLossy() {
        // QUALITY_BINNED is lossy (Phred bins); assert idempotent + length-preserving.
        Codec codec = CodecRegistry.CODEC_REGISTRY.get(
            global.thalion.ttio.Enums.Compression.QUALITY_BINNED);
        byte[] data = new byte[256];
        for (int i = 0; i < 256; i++) data[i] = (byte) i;
        byte[] once = ((DecodedChannel.Bytes) codec.decode(new ChannelPayload.BytesPayload(
            ((EncodedChannel.DatasetBytes) codec.encode(new DecodedChannel.Bytes(data),
                CodecContext.empty())).bytes()), CodecContext.empty())).data();
        byte[] twice = ((DecodedChannel.Bytes) codec.decode(new ChannelPayload.BytesPayload(
            ((EncodedChannel.DatasetBytes) codec.encode(new DecodedChannel.Bytes(once),
                CodecContext.empty())).bytes()), CodecContext.empty())).data();
        assertEquals(data.length, once.length);
        assertArrayEquals(once, twice);
    }
```

- [ ] **Step 2: Run to verify FAIL** (NAME_TOKENIZED_V2 not in registry → NPE on `codec.id()`). Same mvn command.

- [ ] **Step 3: Add adapters to `CodecRegistry.java`** (add imports + classes + map entries).

Add imports:
```java
import global.thalion.ttio.codecs.FqzcompNx16Z;
import global.thalion.ttio.codecs.MateInfoV2;
import global.thalion.ttio.codecs.NameTokenizerV2;
import global.thalion.ttio.codecs.RefDiffV2;
import java.util.LinkedHashMap;
import java.util.List;
```

Add adapter classes (before `build()`):
```java
    static final class NameTokenizedCodec implements Codec {
        public Compression id() { return Compression.NAME_TOKENIZED_V2; }
        public boolean isContextAware() { return false; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            return new DecodedChannel.StrList(NameTokenizerV2.decode(payloadBytes(p)));
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            return new EncodedChannel.DatasetBytes(
                NameTokenizerV2.encode(((DecodedChannel.StrList) v).names()));
        }
    }

    static final class FqzcompCodec implements Codec {
        public Compression id() { return Compression.FQZCOMP_NX16_Z; }
        public boolean isContextAware() { return true; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            FqzcompNx16Z.DecodeResult dr =
                FqzcompNx16Z.decode(payloadBytes(p), ctx.revcompFlags());
            return new DecodedChannel.Bytes(dr.qualities());
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            if (ctx.readLengths() == null || ctx.revcompFlags() == null) {
                throw new IllegalArgumentException(
                    "FQZCOMP_NX16_Z encode requires CodecContext.readLengths + revcompFlags");
            }
            return new EncodedChannel.DatasetBytes(
                FqzcompNx16Z.encode(bytes(v), ctx.readLengths(), ctx.revcompFlags()));
        }
    }

    static final class MateInfoCodec implements Codec {
        public Compression id() { return Compression.MATE_INLINE_V2; }
        public boolean isContextAware() { return true; }
        public boolean needsEmbeddedReference() { return false; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            if (ctx.ownChromIds() == null || ctx.ownPositions() == null || ctx.nRecords() == null) {
                throw new IllegalArgumentException(
                    "MATE_INLINE_V2 decode requires ownChromIds/ownPositions/nRecords");
            }
            MateInfoV2.Triple t = MateInfoV2.decode(
                payloadBytes(p), ctx.ownChromIds(), ctx.ownPositions(), ctx.nRecords());
            return new DecodedChannel.MateInfo(
                t.mateChromIds(), t.matePositions(), t.templateLengths());
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            if (ctx.ownChromIds() == null || ctx.ownPositions() == null) {
                throw new IllegalArgumentException(
                    "MATE_INLINE_V2 encode requires ownChromIds/ownPositions");
            }
            DecodedChannel.MateInfo mi = (DecodedChannel.MateInfo) v;
            return new EncodedChannel.DatasetBytes(MateInfoV2.encode(
                mi.mateChromIds(), mi.matePositions(), mi.templateLengths(),
                ctx.ownChromIds(), ctx.ownPositions()));
        }
    }

    static final class RefDiffCodec implements Codec {
        public Compression id() { return Compression.REF_DIFF_V2; }
        public boolean isContextAware() { return true; }
        public boolean needsEmbeddedReference() { return true; }
        public DecodedChannel decode(ChannelPayload p, CodecContext ctx) {
            // Relocated from GenomicRun.decodeRefDiffV2Sequences: read the blob from
            // the group's refdiff_v2 child, parse header, resolve reference, decode.
            var group = ((ChannelPayload.GroupPayload) p).group();
            var ds = group.openDataset("refdiff_v2");
            byte[] blob = (byte[]) ds.readSlice(0L, ds.shape()[0]);
            RefDiffV2.BlobHeader header = RefDiffV2.parseBlobHeader(blob);
            if (ctx.referenceResolver() == null || ctx.chromosomes() == null) {
                throw new IllegalArgumentException(
                    "REF_DIFF_V2 decode requires referenceResolver + chromosomes");
            }
            java.util.LinkedHashSet<String> uniq =
                new java.util.LinkedHashSet<>(java.util.Arrays.asList(ctx.chromosomes()));
            String chrom;
            if (uniq.isEmpty()) chrom = "";
            else if (uniq.size() > 1) throw new IllegalStateException(
                "REF_DIFF_V2 supports single-chromosome runs only; this run carries " + uniq);
            else chrom = uniq.iterator().next();
            byte[] reference = ctx.referenceResolver().resolve(
                header.referenceUri(), header.referenceMd5(), chrom);
            String[] cigars = ctx.cigarsProvider() != null
                ? ctx.cigarsProvider().get() : new String[0];
            RefDiffV2.Pair out = RefDiffV2.decode(
                blob, ctx.positions(), cigars, reference, ctx.readCount(), ctx.totalBases());
            return new DecodedChannel.Bytes(out.sequences());
        }
        public EncodedChannel encode(DecodedChannel v, CodecContext ctx) {
            if (ctx.offsets() == null || ctx.positions() == null || ctx.reference() == null) {
                throw new IllegalArgumentException(
                    "REF_DIFF_V2 encode requires offsets/positions/reference/md5/uri context");
            }
            String[] cigars = ctx.cigarsProvider() != null
                ? ctx.cigarsProvider().get() : new String[0];
            int rps = ctx.readsPerSlice() != null ? ctx.readsPerSlice() : 10_000;
            byte[] blob = RefDiffV2.encode(bytes(v), ctx.offsets(), ctx.positions(),
                cigars, ctx.reference(), ctx.referenceMd5(), ctx.referenceUri(), rps);
            return new EncodedChannel.GroupLayout(
                new LinkedHashMap<>(Map.of("refdiff_v2", blob)),
                new LinkedHashMap<>());
        }
    }
```

> Before writing `RefDiffCodec.decode`, READ the current `GenomicRun.decodeRefDiffV2Sequences` (`genomics/GenomicRun.java:489-568`) and match its reference-resolution call EXACTLY (the `ReferenceResolver.resolve(...)` signature — uri/md5/chrom order, and how `BlobHeader` exposes uri/md5). Adjust the adapter to the real signatures; report any difference. The decode must be a faithful relocation.

Add to `build()`:
```java
        m.put(Compression.NAME_TOKENIZED_V2, new NameTokenizedCodec());
        m.put(Compression.FQZCOMP_NX16_Z, new FqzcompCodec());
        m.put(Compression.MATE_INLINE_V2, new MateInfoCodec());
        m.put(Compression.REF_DIFF_V2, new RefDiffCodec());
```

- [ ] **Step 4: Run to verify PASS** (name_tok round-trip, flags, QUALITY idempotency). Same mvn command.

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add java/src/main/java/global/thalion/ttio/codecs/registry/CodecRegistry.java java/src/test/java/global/thalion/ttio/codecs/registry/CodecRegistryTest.java && git -C ~/TTI-O commit -m "feat(java-codecs): context-aware codec adapters"
```

---

## Task 4: `codecContext()` builder + route DECODE in `GenomicRun.java`

**Files:** Modify `genomics/GenomicRun.java`.

Goal: route `byteChannelSlice` ladder + the ref_diff/read_names/mate_info side-paths through the registry; behavior byte-identical. The existing `M86CodecWiringTest` + dispatch tests are the gate.

- [ ] **Step 1: Add a cached `codecContext()` helper.** Add a private field `private CodecContext codecCtxCache;` near the other caches (search `decodedByteChannels`). Add:

```java
    private global.thalion.ttio.codecs.registry.CodecContext codecContext() {
        if (codecCtxCache != null) return codecCtxCache;
        int n = index.count();
        int[] readLengths = new int[n];
        int[] revcomp = new int[n];
        long[] positions = new long[n];
        long totalBases = 0L;
        for (int i = 0; i < n; i++) {
            readLengths[i] = index.lengthAt(i);
            revcomp[i] = ((index.flagsAt(i) & 16) != 0) ? 1 : 0;
            positions[i] = index.positionAt(i);
            totalBases += index.lengthAt(i);
        }
        String[] chromosomes = new String[n];
        java.util.LinkedHashMap<String, Integer> nameToId = new java.util.LinkedHashMap<>();
        short[] ownChromIds = new short[n];
        for (int i = 0; i < n; i++) {
            String c = index.chromosomeAt(i);
            chromosomes[i] = c;
            short id;
            if (c == null || c.isEmpty() || c.equals("*")) {
                id = (short) 0xFFFF;
            } else {
                Integer slot = nameToId.get(c);
                if (slot == null) { slot = nameToId.size(); nameToId.put(c, slot); }
                id = (short) (int) slot;
            }
            ownChromIds[i] = id;
        }
        global.thalion.ttio.genomics.ReferenceResolver resolver = null;
        try {
            resolver = buildReferenceResolver();  // see Step 1b
        } catch (RuntimeException e) {
            resolver = null;  // non-HDF5 backend: ref_diff decode raises clearly
        }
        codecCtxCache = global.thalion.ttio.codecs.registry.CodecContext.builder()
            .readLengths(readLengths).revcompFlags(revcomp).readCount(n)
            .positions(positions).totalBases(totalBases).chromosomes(chromosomes)
            .ownChromIds(ownChromIds).ownPositions(positions).nRecords(n)
            .cigarsProvider(() -> allCigars().toArray(new String[0]))
            .referenceResolver(resolver)
            .build();
        return codecCtxCache;
    }
```

> **Step 1b — `buildReferenceResolver()`:** READ how `decodeRefDiffV2Sequences` (`:489-568`) currently constructs its `ReferenceResolver` (it unwraps the HDF5 group → owning file). Extract that exact construction into a private `ReferenceResolver buildReferenceResolver()` helper and call it here. Match the real code; if the encounter-order id derivation in `_decodeMateV2` (`:803-853`) differs from the `nameToId`/`0xFFFF` logic above, mirror the real one EXACTLY (it is the byte-equality contract for mate_info). Confirm `allCigars()` exists and returns `List<String>`.

- [ ] **Step 2: Route the byte-channel ladder.** In `byteChannelSlice`, replace the `if (codecId == …RANS_ORDER0…) … else …` chain (the block that sets `decoded`, `:436-466`) with:

```java
        byte[] decoded;
        global.thalion.ttio.Enums.Compression comp =
            global.thalion.ttio.Enums.Compression.values()[codecId];
        var codec = global.thalion.ttio.codecs.registry.CodecRegistry.CODEC_REGISTRY.get(comp);
        if (codec == null) {
            throw new IllegalStateException(
                "signal_channel '" + name + "': @compression=" + codecId
                + " is not a supported TTIO codec id");
        }
        decoded = ((global.thalion.ttio.codecs.registry.DecodedChannel.Bytes)
            codec.decode(new global.thalion.ttio.codecs.registry.ChannelPayload.BytesPayload(all),
                codecContext())).data();
```

Keep unchanged: the `codecId == 0` raw `readSlice` return, the `all = (byte[]) ds.readSlice(0L, total)` read, and the `decodedByteChannels.put(name, decoded); System.arraycopy(...)` tail. (Guard `codecId` against out-of-range before `values()[codecId]` — if the existing code already validates, fine; otherwise wrap in a range check that throws the same message.)

- [ ] **Step 3: Route the ref_diff side-path.** Where `byteChannelSlice` (or its caller) invokes `decodeRefDiffV2Sequences()` (gated by `isSequencesRefDiffV2()` near `:417`), replace the call with:

```java
            var sig = group.openGroup("signal_channels");
            byte[] decoded = ((global.thalion.ttio.codecs.registry.DecodedChannel.Bytes)
                global.thalion.ttio.codecs.registry.CodecRegistry.CODEC_REGISTRY
                    .get(global.thalion.ttio.Enums.Compression.REF_DIFF_V2)
                    .decode(new global.thalion.ttio.codecs.registry.ChannelPayload.GroupPayload(
                        sig.openGroup("sequences")), codecContext())).data();
```

Preserve the caches the original set (`decodedByteChannels` and any ref_diff cache). Then delete the now-unused `decodeRefDiffV2Sequences` method (the adapter is its faithful relocation) — only if the build stays green; else leave it.

- [ ] **Step 4: Route read_names + mate_info.** READ `readNameAt` (`:601-645`) and the mate_info path (`mateChromAt`/`_decodeMateV2` `:803-853`). Replace only their codec-call lines:
- read_names: `((DecodedChannel.StrList) CODEC_REGISTRY.get(Compression.NAME_TOKENIZED_V2).decode(new ChannelPayload.BytesPayload(blob), codecContext())).names()`
- mate_info: `var mi = (DecodedChannel.MateInfo) CODEC_REGISTRY.get(Compression.MATE_INLINE_V2).decode(new ChannelPayload.BytesPayload(blob), codecContext()); ... mi.mateChromIds()/mi.matePositions()/mi.templateLengths()`
Preserve the surrounding parsing (chrom_names sidecar resolution for mate_info) and caches.
- cigars: leave the length-prefix framing in `cigarAt`, but route its inner rANS through `CODEC_REGISTRY.get(Compression.RANS_ORDER0/1).decode(...)` (the inner blob is a plain rANS stream). Confirm against the current `decodeLengthPrefixConcat` that only the rANS call is swapped, framing untouched.

- [ ] **Step 5: Run the codec/genomic suites — MUST stay green**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -Dtest=CodecRegistryTest,M86CodecWiringTest,RefDiffV2DispatchTest,MateInfoV2DispatchTest,NameTokenizedV2DispatchTest,GenomicRunTest test 2>&1 | tail -20'`
Expected: all pass. If anything fails, the registry decode is not byte-identical — debug; do not alter codec bodies.

- [ ] **Step 6: Commit**

```bash
git -C ~/TTI-O add java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java && git -C ~/TTI-O commit -m "refactor(java-codecs): route genomic decode through codec registry"
```

---

## Task 5: Route ENCODE in `SpectralDataset.java`

**Files:** Modify `SpectralDataset.java`.

- [ ] **Step 1: Route `writeByteChannelWithCodec`.** Replace the `switch (codecOverride) { case RANS_ORDER0 -> … }` block (`:2220-2232`) that sets `encoded` with:

```java
        var codec = global.thalion.ttio.codecs.registry.CodecRegistry.CODEC_REGISTRY.get(codecOverride);
        if (codec == null) {
            throw new IllegalArgumentException(
                "writeByteChannelWithCodec: unsupported codec " + codecOverride);
        }
        byte[] encoded = ((global.thalion.ttio.codecs.registry.EncodedChannel.DatasetBytes)
            codec.encode(new global.thalion.ttio.codecs.registry.DecodedChannel.Bytes(data),
                global.thalion.ttio.codecs.registry.CodecContext.empty())).bytes();
```

Keep the dataset-creation + `setAttribute("compression", codecIdFor(codecOverride))` tail. (Byte channels here are only rans/base_pack/quality — none need a context; `writeByteChannelWithCodec`'s whitelist excludes delta, so `empty()` is correct.)

- [ ] **Step 2: Route the writer methods.** For `writeQualitiesFqzcompNx16Z` (`:2168`), `writeMateInfoV2` (`:1716`), and the name_tok inline writer (`:1564-1610`): READ each, then replace the direct `FqzcompNx16Z.encode(...)` / `MateInfoV2.encode(...)` / `NameTokenizerV2.encode(...)` call with the registry, building an encode-time `CodecContext`:
- fqzcomp: `.readLengths(...).revcompFlags(...)` sourced exactly as the method does now (read_lengths from run lengths, revcomp from flag&16).
- mate_info: `.ownChromIds(...).ownPositions(...)`, value `new DecodedChannel.MateInfo(mateChromIds, matePositions, templateLengths)`.
- name_tok: value `new DecodedChannel.StrList(names)`, empty ctx.
Take `EncodedChannel.DatasetBytes.bytes()` and write exactly as before (same dataset + `@compression`).

- [ ] **Step 3: Route ref_diff encode.** In `writeSequencesRefDiff` (`:2050`), READ how it currently calls `RefDiffV2.encode(...)` and writes the `sequences` group + `refdiff_v2` child + attrs. Replace the `RefDiffV2.encode(...)` call with the registry: build a `CodecContext` carrying `offsets/positions/reference/referenceMd5/referenceUri/readsPerSlice` + `cigarsProvider`, call `CODEC_REGISTRY.get(REF_DIFF_V2).encode(new DecodedChannel.Bytes(sequences), ctx)`, then materialize the `sequences` group + `refdiff_v2` child + `@compression` from the returned `EncodedChannel.GroupLayout` (children + attrs). The group/child bytes + attrs MUST be byte-identical to before.

- [ ] **Step 4: Run encode + cross-codec suites — MUST stay green**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -Dtest=M86CodecWiringTest,RefDiffV2DispatchTest,MateInfoV2DispatchTest,NameTokenizedV2DispatchTest,FqzcompNx16ZV4DispatchTest,CodecRegistryTest test 2>&1 | tail -20'`
Expected: all pass; on-disk bytes unchanged.

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add java/src/main/java/global/thalion/ttio/SpectralDataset.java && git -C ~/TTI-O commit -m "refactor(java-codecs): route genomic encode through codec registry"
```

---

## Task 6: `needsEmbeddedReference` wiring + dedup the embed predicate

**Files:** Modify `SpectralDataset.java`; extend `CodecRegistryTest.java`.

**CONTEXT (the careful part):** Java's reference-embed decision is the `useRefDiffPath` boolean duplicated at `embedReferencesForRuns:1936-1939` and `writeGenomicRunSubtree:1447-1450`. It is **default-path-based** (`signalCompression == ZLIB && no "sequences" override`), structurally different from Python's override-based predicate. The embed decision must stay byte-identical (this is the trap that BLOCKED the Python T6). This task ONLY: (a) extracts the duplicated boolean into one private helper (pure dedup), and (b) adds a registry-level parity test for `needsEmbeddedReference`. Do NOT change the embed truth value.

- [ ] **Step 1: Add parity tests** — append to `CodecRegistryTest.java`:

```java
    @Test
    void needsEmbeddedReferenceOnlyRefDiff() {
        var embed = new java.util.HashSet<global.thalion.ttio.Enums.Compression>();
        CodecRegistry.CODEC_REGISTRY.forEach((cid, c) -> {
            if (c.needsEmbeddedReference()) embed.add(cid);
        });
        assertEquals(java.util.Set.of(global.thalion.ttio.Enums.Compression.REF_DIFF_V2), embed);
    }

    @Test
    void registryGetSafeForUnregisteredValidCodecs() {
        // NONE/ZLIB/LZ4 are valid Compression members but not registered codecs;
        // .get(...) must return null (no exception) — membership-safe.
        for (var c : List.of(global.thalion.ttio.Enums.Compression.NONE,
                global.thalion.ttio.Enums.Compression.ZLIB,
                global.thalion.ttio.Enums.Compression.LZ4)) {
            assertNull(CodecRegistry.CODEC_REGISTRY.get(c));
        }
    }
```

Run them — expect PASS (registry already has the flags). If `NONE`/`ZLIB`/`LZ4` aren't the exact unregistered member names, use any 2-3 valid members not in the registry.

- [ ] **Step 2: Dedup the embed predicate.** READ both sites (`embedReferencesForRuns:1936-1939` and `writeGenomicRunSubtree:1447-1450`). Extract the identical expression into one private helper on `SpectralDataset`:

```java
    /** True iff a written genomic run's sequences default to the ref-diff path
     *  (ZLIB default codec + no explicit "sequences" override), which embeds a
     *  reference. Single source of truth for the two former inlined copies. */
    private static boolean usesRefDiffDefaultPath(WrittenGenomicRun run) {
        return run.signalCompression() == Enums.Compression.ZLIB
            && !run.signalCodecOverrides().containsKey("sequences");
    }
```

> Match the EXACT expression at both sites (the `WrittenGenomicRun` accessor names — `signalCompression()`, `signalCodecOverrides()` — verified during read). Replace both inlined copies with `usesRefDiffDefaultPath(run)`. Do NOT change the surrounding gates (`run.embedReference()`, `run.referenceChromSeqs() != null`). The boolean must be identical.

- [ ] **Step 3: Run the embed + codec suites — MUST stay green** (embed behavior unchanged):

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q -Dtest=CodecRegistryTest,M86CodecWiringTest,RefDiffV2DispatchTest test 2>&1 | tail -15'`
Plus any reference-embed test (grep `embedReference`/`References` in `src/test`). Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git -C ~/TTI-O add java/src/main/java/global/thalion/ttio/SpectralDataset.java java/src/test/java/global/thalion/ttio/codecs/registry/CodecRegistryTest.java && git -C ~/TTI-O commit -m "refactor(java-codecs): needsEmbeddedReference flag + dedup ref-diff embed predicate"
```

---

## Task 7: Completeness guard, full regression, CHANGELOG

**Files:** extend `CodecRegistryTest.java`; modify `CHANGELOG.md`.

- [ ] **Step 1: Add completeness guard** — append:

```java
    @Test
    void registryCoversAllRealCodecIds() {
        var expected = java.util.Set.of(
            global.thalion.ttio.Enums.Compression.RANS_ORDER0,
            global.thalion.ttio.Enums.Compression.RANS_ORDER1,
            global.thalion.ttio.Enums.Compression.BASE_PACK,
            global.thalion.ttio.Enums.Compression.QUALITY_BINNED,
            global.thalion.ttio.Enums.Compression.DELTA_RANS_ORDER0,
            global.thalion.ttio.Enums.Compression.FQZCOMP_NX16_Z,
            global.thalion.ttio.Enums.Compression.MATE_INLINE_V2,
            global.thalion.ttio.Enums.Compression.REF_DIFF_V2,
            global.thalion.ttio.Enums.Compression.NAME_TOKENIZED_V2);
        assertTrue(CodecRegistry.CODEC_REGISTRY.keySet().containsAll(expected));
    }
```

- [ ] **Step 2: Run the full Java test suite**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q test 2>&1 | tail -25'`
Expected: BUILD SUCCESS, 0 failures. (No wire change → all existing genomic/codec/transport tests pass.) If failures appear, STOP and report — do not paper over.

- [ ] **Step 3: Add the CHANGELOG entry** — under `## [Unreleased]`:

```markdown
### Changed — Codec dispatch unified behind a registry (Java)

Java's genomic codec dispatch (the decode ladder + four bespoke
ref_diff/fqzcomp/name_tok/mate_info side-paths and the encode switch + writer
methods) is replaced by a single `Codec` registry keyed by `Compression`
(`codecs/registry/`), fronted by a uniform `Codec` interface, a `CodecContext`
value object, and sealed `DecodedChannel`/`EncodedChannel`/`ChannelPayload`
unions. Codecs expose `isContextAware` and `needsEmbeddedReference` (REF_DIFF_V2
only); the duplicated `useRefDiffPath` embed predicate is consolidated into one
helper. `DELTA_RANS_ORDER0` is now registered (previously unwired). No
wire/on-disk format change; all byte-equality and cross-language fixtures
unchanged. Mirrors the Python registry (PR #209); ObjC port is the remaining
parity follow-on.
```

- [ ] **Step 4: Commit**

```bash
git -C ~/TTI-O add java/src/test/java/global/thalion/ttio/codecs/registry/CodecRegistryTest.java CHANGELOG.md && git -C ~/TTI-O commit -m "test(java-codecs): registry completeness guard; changelog"
```

---

## Notes / gotchas

- **Build with JDK 22+:** always `JAVA_HOME=~/jdk25 mvn`. A Java-21 JRE cannot load the class-file-66 output.
- **No wire change is load-bearing:** every encode adapter must produce byte-identical output to the direct codec call. `M86CodecWiringTest` + the cross-language matrix are the gate. If any on-disk byte differs, stop and diff.
- **No embed-behavior change:** Task 6 is an extract-only dedup; the `usesRefDiffDefaultPath` boolean must equal both former inlined copies exactly. Verify against reference-embed tests.
- **ref_diff is the hard case** (group layout + reference resolution from blob header + single-chromosome constraint). Its decode adapter is a faithful relocation of `decodeRefDiffV2Sequences`; verify `RefDiffV2.parseBlobHeader`/`ReferenceResolver.resolve` signatures before relying on them. Its encode relocates `writeSequencesRefDiff`'s codec call.
- **mate_info `ownChromIds` encounter-order** derivation in `codecContext()` must mirror `_decodeMateV2`'s exact id assignment (incl. the `0xFFFF` sentinel) — byte-equality contract.
- **`Compression.values()[codecId]`** returns a valid enum constant for reserved/unregistered ids; always go through `CODEC_REGISTRY.get(...)` and null-check (membership-safe), never assume presence.
- **Follow-on:** ObjC port (`@protocol` + class clusters + `NSDictionary` registry), its own spec/plan.
