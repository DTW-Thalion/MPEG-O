# Streaming import/export and `blocks_v1` in Java — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Java reads and writes the `blocks_v1` genomic layout (format-spec §10.12), writes it by default, and streams BAM/FASTQ/mzML import and SAM/BAM/FASTQ/mzML export with bounded memory, matching the Python implementation merged in PR #290.

**Architecture:** Providers gain extendable datasets and a `UINT64` compound kind. A block encoder writes each block through the existing v1.8 writer into a `MemoryProvider` root and harvests the bytes; `GenomicStreamWriter` appends blobs to extendable channel datasets and rows to `blocks/index`. The reader materialises one block as a v1.8-shaped memory group and runs the existing `GenomicRun` decode over it. MS streaming needs no layout change: `SpectralStreamWriter` appends extendable datasets and finalises the FDZ1 header; `AcquisitionRun` decodes channel ranges lazily.

**Tech Stack:** Java 21, Maven, jarhdf5 1.14 (JNI), htsjdk, SAX (mzML), JUnit 5. Build/test from `java/`: `mvn -q -B test -Dtest=<Class>` (native libs via `-Dhdf5.native.path`; the default in `pom.xml` is `/usr/local/lib:../native/_build`).

**Spec:** `docs/superpowers/specs/2026-08-17-streaming-blocks-v1-java-design.md` (format: `docs/format-spec.md` §10.12; Python reference: `python/src/ttio/genomic/{stream_writer,_blocks,_block_view,lazy_reference}.py`, `python/src/ttio/spectral_stream_writer.py`, `python/src/ttio/acquisition_run.py`).

## Global Constraints

- Every byte a Java writer emits under `blocks_v1` must be what the v1.8 whole-run writer would emit for that block's reads (the cross-language contract). No codec wire change.
- Block index column order and types exactly as §10.12.2 (19 columns; `read_start,n_reads,base_start,n_bases,<ch>_off,<ch>_len ×5,<ch>_codec ×5`; channel order `sequences,qualities,read_names,cigars,mate_info`).
- Blocks never span chromosomes. Forced codecs: cigars RANS_ORDER0; qualities FQZCOMP_NX16_Z, RANS_ORDER0 when the block has a zero-length read; sequences RANS_ORDER1 without a reference.
- `sequences/data` is always a group child under `blocks_v1`; channel datasets are unfiltered extendable `uint8`, 256 KiB chunks; codec 0 keeps zlib.
- Java reads both layouts; unknown `@layout` throws `IllegalStateException`.
- Public API stays source-compatible: only overloads, default methods and one new `WrittenGenomicRun` component with a delegating constructor.
- No AI attribution anywhere (commit messages, comments, docs). No change-describing comments in source; comments state what the code does.
- Cross-language fixtures stay pinned to `opt_legacy_whole_channel=True` (un-pinning is sub-project 4). The Python conformance matrix must stay green after every task that touches a shared surface.
- Commit after each task; run the named test class before committing; run the full Java suite (`mvn -q -B test`) at Tasks 5, 8 and 12.

Repository is `~/TTI-O` on WSL Ubuntu, branch `streaming-blocks-v1-java`. Java sources: `java/src/main/java/global/thalion/ttio/`; tests: `java/src/test/java/global/thalion/ttio/`. Paths below are relative to `java/src/main/java/global/thalion/ttio/` unless they start with `java/`, `python/` or `tio-browser/`.

---

### Task 1: Extendable datasets and `UINT64` in the four providers

**Files:**
- Modify: `providers/CompoundField.java` (add `UINT64`)
- Modify: `providers/StorageDataset.java` (`extendable()`, `append`, `writeSlice`, canonical UINT64)
- Modify: `providers/StorageGroup.java` (extendable overloads)
- Modify: `hdf5/Hdf5Group.java` (unlimited maxdims + chunk on `length == 0`), `hdf5/Hdf5Dataset.java` (mutable length, `append`, `writeSlice`, `isExtendable`), `hdf5/Hdf5CompoundIO.java` (`UINT64` kind, `createExtendableCompound`, `appendCompoundRows`, `isExtendable`), `providers/Hdf5Provider.java` (adapters)
- Modify: `providers/MemoryProvider.java`, `providers/SqliteProvider.java`, `providers/ZarrProvider.java`
- Test: `java/src/test/java/global/thalion/ttio/ProviderTest.java`

**Interfaces:**
- Produces: `StorageGroup.createDataset(name, precision, length, chunkSize, compression, level, boolean extendable)`; `StorageGroup.createCompoundDataset(name, fields, count, boolean extendable, int chunkRows)`; `StorageDataset.extendable()`, `append(Object)`, `writeSlice(long offset, Object data)`; `CompoundField.Kind.UINT64`. Compound `append`/`writeAll` accept `List<Object[]>` in field order on every provider (SQLite converts to its map rows internally); `readRows()` stays the uniform read.

- [ ] **Step 1: Failing tests** — add to `ProviderTest` (uses the existing `urlFor(provider)` helper; extend the `@ValueSource` to `{"hdf5","memory","sqlite","zarr"}` for the new tests only; sqlite/zarr URLs: `urlFor` already returns a temp path per provider — check the helper and add branches if it only knows hdf5/memory):

```java
@ParameterizedTest
@ValueSource(strings = {"hdf5", "memory", "sqlite", "zarr"})
void extendablePrimitiveAppendAndSlice(String provider) {
    String url = urlFor(provider);
    try (StorageProvider p = ProviderRegistry.open(url, StorageProvider.Mode.CREATE, provider)) {
        StorageGroup root = p.rootGroup();
        try (StorageDataset ds = root.createDataset("blob", Precision.UINT8, 0, 4,
                Compression.NONE, 0, true)) {
            assertTrue(ds.extendable());
            assertEquals(0, ds.length());
            ds.append(new byte[]{1, 2, 3});
            ds.append(new byte[]{4, 5, 6, 7, 8});
            ds.append(new byte[0]);
            assertEquals(8, ds.length());
            assertArrayEquals(new byte[]{3, 4, 5, 6}, (byte[]) ds.readSlice(2, 4));
            ds.writeSlice(1, new byte[]{9, 9});
            assertArrayEquals(new byte[]{1, 9, 9, 4, 5, 6, 7, 8}, (byte[]) ds.readAll());
        }
        try (StorageDataset ds = root.createDataset("vals", Precision.FLOAT64, 0, 2,
                Compression.NONE, 0, true)) {
            ds.append(new double[]{1.5, 2.5, 3.5});
            assertArrayEquals(new double[]{2.5, 3.5}, (double[]) ds.readSlice(1, 2), 0.0);
        }
        try (StorageDataset fixed = root.createDataset("fixed", Precision.UINT8, 2, 0,
                Compression.NONE, 0)) {
            assertFalse(fixed.extendable());
            assertThrows(UnsupportedOperationException.class, () -> fixed.append(new byte[]{1}));
        }
        assertThrows(IllegalArgumentException.class, () -> root.createDataset("bad",
                Precision.UINT8, 0, 0, Compression.NONE, 0, true));
    }
    try (StorageProvider p = ProviderRegistry.open(url, StorageProvider.Mode.READ, provider)) {
        try (StorageDataset ds = p.rootGroup().openDataset("blob")) {
            assertTrue(ds.extendable());
            assertEquals(8, ds.length());
            assertArrayEquals(new byte[]{1, 9, 9, 4, 5, 6, 7, 8}, (byte[]) ds.readAll());
        }
    }
    if ("memory".equals(provider)) MemoryProvider.discardStore(url);
}

@ParameterizedTest
@ValueSource(strings = {"hdf5", "memory", "sqlite", "zarr"})
void extendableCompoundWithUint64(String provider) {
    String url = urlFor(provider);
    List<CompoundField> fields = List.of(
        new CompoundField("start", CompoundField.Kind.UINT64),
        new CompoundField("n", CompoundField.Kind.UINT32),
        new CompoundField("score", CompoundField.Kind.FLOAT64));
    try (StorageProvider p = ProviderRegistry.open(url, StorageProvider.Mode.CREATE, provider)) {
        try (StorageDataset ds = p.rootGroup().createCompoundDataset("idx", fields, 0, true, 2)) {
            assertTrue(ds.extendable());
            ds.append(List.of(new Object[]{0L, 4, 0.5}));
            ds.append(List.of(new Object[]{4L, 1, 1.5}, new Object[]{5L, 2, 2.5}));
            assertEquals(3, ds.length());
            List<Map<String, Object>> rows = ds.readRows();
            assertEquals(3, rows.size());
            assertEquals(5L, ((Number) rows.get(2).get("start")).longValue());
            assertEquals(2, ((Number) rows.get(2).get("n")).intValue());
            assertEquals(2.5, ((Number) rows.get(2).get("score")).doubleValue(), 0.0);
        }
    }
    try (StorageProvider p = ProviderRegistry.open(url, StorageProvider.Mode.READ, provider)) {
        try (StorageDataset ds = p.rootGroup().openDataset("idx")) {
            assertEquals(3, ds.readRows().size());
            assertEquals(CompoundField.Kind.UINT64, ds.compoundFields().get(0).kind());
            byte[] canon = ds.readCanonicalBytes();
            assertEquals(3 * (8 + 4 + 8), canon.length);
        }
    }
    if ("memory".equals(provider)) MemoryProvider.discardStore(url);
}
```

- [ ] **Step 2: Run** `mvn -q -B test -Dtest=ProviderTest` → compile failure (`createDataset` 7-arg, `Kind.UINT64`).

- [ ] **Step 3: API** — `CompoundField.Kind`: add `UINT64` after `INT64` with javadoc "Unsigned 64-bit integer field; Java `long`". `StorageDataset`: add

```java
default boolean extendable() { return false; }
default void append(Object data) {
    throw new UnsupportedOperationException("dataset '" + name() + "' is not extendable");
}
default void writeSlice(long offset, Object data) {
    throw new UnsupportedOperationException(getClass().getSimpleName() + " does not implement writeSlice");
}
```
and in `writeCanonicalField` a `case UINT64` identical to `INT64` (8-byte LE). `StorageGroup`: add

```java
default StorageDataset createDataset(String name, Precision precision, long length, int chunkSize,
        Compression compression, int compressionLevel, boolean extendable) {
    if (extendable) throw new UnsupportedOperationException(
        getClass().getSimpleName() + " does not implement extendable datasets");
    return createDataset(name, precision, length, chunkSize, compression, compressionLevel);
}
default StorageDataset createCompoundDataset(String name, List<CompoundField> fields, long count,
        boolean extendable, int chunkRows) {
    if (extendable) throw new UnsupportedOperationException(
        getClass().getSimpleName() + " does not implement extendable compound datasets");
    return createCompoundDataset(name, fields, count);
}
static void requireChunkForExtendable(boolean extendable, long chunk) {
    if (extendable && chunk <= 0) throw new IllegalArgumentException(
        "extendable datasets need chunkSize > 0");
}
```

- [ ] **Step 4: HDF5** — `Hdf5Group.createDataset(name, precision, length, chunkSize, compression, level)` gains a private variant with `boolean extendable`: dataspace `H5Screate_simple(1, {length}, extendable ? {H5S_UNLIMITED} : null)`; the chunk plist is set when `chunkSize > 0 && (length > 0 || extendable)` with chunk `extendable ? chunkSize : min(chunkSize, length)`; the public 6-arg method delegates with `false`; add public `createDataset(..., boolean extendable)`. `Hdf5Dataset`: `length` becomes non-final; add `boolean extendable` field set in a new constructor (`Hdf5Group.openDataset` and `createDataset` compute it: after `H5Dget_space`, `H5Sget_simple_extent_dims(space, dims, maxdims)` and `extendable = rank == 1 && maxdims[0] == HDF5Constants.H5S_UNLIMITED`); add

```java
public boolean isExtendable() { return extendable; }
public void append(Object data) {
    long n = elementCount(data);            // array length by precision (COMPLEX128: length/2)
    if (n == 0) return;
    file.lockForWriting();
    long fspace = -1, mspace = -1, htype = -1;
    try {
        long newLen = length + n;
        H5.H5Dset_extent(datasetId, new long[]{newLen});
        fspace = H5.H5Dget_space(datasetId);
        H5.H5Sselect_hyperslab(fspace, HDF5Constants.H5S_SELECT_SET, new long[]{length}, null, new long[]{n}, null);
        mspace = H5.H5Screate_simple(1, new long[]{n}, null);
        htype = Hdf5Group.hdf5TypeFor(precision);
        Object buf = precision == Precision.COMPLEX128 ? doublesToCompoundBytes((double[]) data) : data;
        if (H5.H5Dwrite(datasetId, htype, mspace, fspace, HDF5Constants.H5P_DEFAULT, buf) < 0)
            throw new Hdf5Errors.DatasetWriteException("H5Dwrite (append) failed");
        length = newLen;
    } catch (HDF5LibraryException e) {
        throw new Hdf5Errors.DatasetWriteException("append failed: " + e.getMessage());
    } finally { /* close mspace, fspace, COMPLEX128 htype; unlock */ }
}
public void writeSlice(long offset, Object data) { /* same as append without set_extent; offset+n <= length else OutOfRangeException */ }
```
`Hdf5Provider.Hdf5GroupAdapter.createDataset(7-arg)`: `StorageGroup.requireChunkForExtendable`; call the new `Hdf5Group.createDataset(..., extendable)`. `Hdf5DatasetAdapter`: `extendable()` → `delegate.isExtendable()`; `append`/`writeSlice` delegate; `shape()` already reads `delegate.getLength()`.

Compound: `Hdf5CompoundIO.FieldKind` gains `UINT64(8, HDF5Constants.H5T_NATIVE_UINT64)`; every `switch` on kind in `writeCompoundOriginal`, the split writer's primitive pass, `readCompoundPrimitives`, `readCompoundFull` and `Hdf5Provider.toSchema/fromIoKind` handles it like `INT64` (`putLong`/`getLong`). Add to `Hdf5CompoundIO`:

```java
/** Create an empty, chunked, unlimited compound dataset (primitive kinds only). */
public static void createExtendableCompound(Hdf5Group parent, String name, Schema schema, int chunkRows)
/** Append rows (Object[] per row, field order) by extending and hyperslab-writing packed bytes. */
public static void appendCompoundRows(Hdf5Group parent, String name, Schema schema, List<Object[]> rows)
public static boolean isExtendable(Hdf5Group parent, String name)   // maxdims[0] == UNLIMITED
```
Both throw `UnsupportedOperationException("extendable compound datasets support primitive kinds only")` when the schema has a VL kind. `Hdf5CompoundDatasetAdapter`: add fields `extendable`, `chunkRows`; `createCompoundDataset(5-arg)` creates the dataset immediately when `extendable` (so `openDataset` sees it before any row is written); `append` → `appendCompoundRows`; `writeAll` on an extendable dataset with `count == 0` → `appendCompoundRows` (so callers that write in one go still work); `shape()` reads the current extent (`H5Dopen`+`H5Sget_simple_extent_dims`) when extendable; `extendable()` → stored flag or `isExtendable` probe on open. Member-type inference in `Hdf5Provider` (the `H5Tget_member_type` loop): `cls == H5T_INTEGER && size == 8` → `H5Tget_sign(mt) == H5T_SGN_NONE ? UINT64 : INT64`.

- [ ] **Step 5: Memory** — `MemDataset` gains `boolean extendable`; `MemoryGroup.createDataset(7-arg)`/`createCompoundDataset(5-arg)` pass it (require chunk); `append`: primitive → concatenate typed arrays (`byte[]`,`short[]`,`int[]`,`long[]`,`float[]`,`double[]`) and update `shape[0]`; compound → `List<Object[]>` `addAll` (accept `List<Map>` too by converting via field order); `writeSlice` → `System.arraycopy` in place; `readAll` on a never-written extendable dataset returns an empty typed array (helper `emptyArrayFor(precision)`) rather than `null`.

- [ ] **Step 6: SQLite** — schema: add `extendable INTEGER NOT NULL DEFAULT 0` to the `datasets` DDL and an `ensureExtendableColumn(conn)` (`PRAGMA table_info(datasets)`; `ALTER TABLE datasets ADD COLUMN extendable INTEGER NOT NULL DEFAULT 0` when absent) called from `doOpen` after `initDb`, as Python's `_ensure_extendable_column` does. `openDataset` selects the column; `createDataset(7-arg)`/`createCompoundDataset(5-arg)` insert it. `SqliteDataset.append`: read the blob (or rows), concatenate, `writeAll` (read-modify-write, like Python); `writeSlice`: read blob, patch, write. `slicePrimitive`/`packPrimitive` already cover the types; add `short[]` if missing.

- [ ] **Step 7: Zarr** — `ZPrimitiveDataset`: `extendable` from a `_ttio_extendable` entry in the array's `attributes` (write it in `createDataset(7-arg)` via `writeZArray` attributes; Python uses the same key); `append`: `readAll` → concatenate → update `shape[0]` in memory and rewrite `zarr.json` (`writeZArray(dir, shape, chunks, precision)` keeping attributes) → `writeAll`; `writeSlice` likewise. `sliceTypedArray` gains `byte[]` and `short[]`. `ZCompoundDataset`: `extendable` from the same attribute; `append` reads the JSON rows, appends, writes back and updates `COUNT_ATTR`.

- [ ] **Step 8: Run** `mvn -q -B test -Dtest=ProviderTest` → PASS. Then `mvn -q -B test -Dtest='Hdf5DatasetTest,VLBytesCompoundTest,SpectralDatasetProviderRoutingTest,ProtectionTest'` → PASS (compound kind switches touched).

- [ ] **Step 9: Commit** `feat(providers): extendable datasets, writeSlice and the UINT64 compound kind`

---

### Task 2: The v1.8 genomic writer over a `MemoryProvider` root, `GenomicWriteContext`

**Files:**
- Create: `genomics/GenomicWriteContext.java`
- Modify: `SpectralDatasetGenomicWriter.java` (`writeGenomicRunSubtree` overload; thread context into `GenomicIndex.writeTo`, `writeMateInfoV2`, `writeSequencesRefDiff`)
- Modify: `genomics/GenomicIndex.java` (`writeTo(StorageGroup, Map<String,Integer> nameToId)`)
- Test: `java/src/test/java/global/thalion/ttio/genomics/GenomicBlocksTest.java` (created here, extended in Task 3)

**Interfaces:**
- Produces: `record GenomicWriteContext(Map<String,Integer> chromNameToId, byte[] referenceMd5)` with `static GenomicWriteContext none()`; `SpectralDatasetGenomicWriter.writeGenomicRunSubtree(StorageGroup parent, String name, WrittenGenomicRun run, GenomicWriteContext ctx)`; `GenomicIndex.writeTo(StorageGroup idxGroup, Map<String,Integer> nameToId)` (null = per-run map, as today).

- [ ] **Step 1: Failing test** — `GenomicBlocksTest`:

```java
static WrittenGenomicRun m87() throws IOException {
    return new BamReader(Paths.get("src","test","resources","ttio","fixtures","genomic","m87_test.bam"))
        .toGenomicRun("genomic_0001");
}

@Test
void v18WriterRoundTripsThroughMemoryProvider() throws Exception {
    WrittenGenomicRun run = m87();
    StorageGroup root = MemoryProvider.open("memory://gb-roundtrip", StorageProvider.Mode.CREATE).rootGroup();
    SpectralDatasetGenomicWriter.writeGenomicRunSubtree(root, "r", run, GenomicWriteContext.none());
    try (GenomicRun g = GenomicRun.readFrom(root.openGroup("r"), "r")) {
        assertEquals(run.readCount(), g.readCount());
        for (int i = 0; i < run.readCount(); i++) {
            AlignedRead r = g.readAt(i);
            assertEquals(run.readNames().get(i), r.readName());
            assertEquals(run.cigars().get(i), r.cigar());
            assertEquals(run.chromosomes().get(i), r.chromosome());
        }
    }
}

@Test
void sharedChromMapGivesStableIdsAcrossTwoWrites() throws Exception {
    WrittenGenomicRun run = m87();
    Map<String,Integer> shared = new LinkedHashMap<>();
    shared.put("chrZ", 0);                       // pre-seeded id must survive
    StorageGroup root = MemoryProvider.open("memory://gb-shared", StorageProvider.Mode.CREATE).rootGroup();
    SpectralDatasetGenomicWriter.writeGenomicRunSubtree(root, "a", run, new GenomicWriteContext(shared, null));
    short[] ids = (short[]) root.openGroup("a").openGroup("genomic_index").openDataset("chromosome_ids").readAll();
    assertEquals(shared.get(run.chromosomes().get(0)).intValue(), ids[0]);
    assertTrue(shared.get(run.chromosomes().get(0)) >= 1);
}
```
(the test class is package `global.thalion.ttio.genomics`; `SpectralDatasetGenomicWriter` is package-private in `global.thalion.ttio` — make the two static methods it needs `public` with `/** Internal. */` javadoc, or place the test in package `global.thalion.ttio`. Choose: put `GenomicBlocksTest` in package `global.thalion.ttio` and keep the writer package-private.)

- [ ] **Step 2: Run** `mvn -q -B test -Dtest=GenomicBlocksTest` → compile failure.

- [ ] **Step 3: Implement** — `GenomicWriteContext`:

```java
package global.thalion.ttio.genomics;
public record GenomicWriteContext(Map<String, Integer> chromNameToId, byte[] referenceMd5) {
    public static GenomicWriteContext none() { return new GenomicWriteContext(null, null); }
}
```
`GenomicIndex.writeTo(StorageGroup)` delegates to `writeTo(idxGroup, null)`; the new overload uses the given map when non-null (`slot = nameToId.get(name); if null → nameToId.put(name, nameToId.size())`, keeping the 65535 guard) and writes `chromosome_names` from the map's key order. `writeMateInfoV2(sc, run)` → `writeMateInfoV2(sc, run, Map<String,Integer> shared)`: when `shared != null` use it as `chromToId` (extend in place with own chromosomes then mate-only names) instead of a fresh map. `writeSequencesRefDiff(sc, run)` → `(sc, run, byte[] md5)`: `md5 != null ? md5 : referenceMd5ForRun(run)`. `writeGenomicRunSubtree(parent, name, run)` → `writeGenomicRunSubtree(parent, name, run, GenomicWriteContext.none())`; the 4-arg version passes `ctx.chromNameToId()` to `idx.writeTo` and `writeMateInfoV2`, `ctx.referenceMd5()` to `writeSequencesRefDiff`.

- [ ] **Step 4: Run** the test → PASS. Run `mvn -q -B test -Dtest='GenomicRunTest,MateInfoV2DispatchTest,RefDiffV2DispatchTest,SpectralDatasetTest'` → PASS.

- [ ] **Step 5: Commit** `refactor(genomics): thread a write context (shared chromosome ids, reference md5) through the genomic writer`

---

### Task 3: Block encoder `genomics/GenomicBlocks`

**Files:**
- Create: `genomics/GenomicBlocks.java`
- Modify: `genomics/WrittenGenomicRun.java` (`optLegacyWholeChannel` component + delegating constructor; `withSignalCodecOverrides`, `withProvenance` helpers if absent)
- Test: `java/src/test/java/global/thalion/ttio/GenomicBlocksTest.java`

**Interfaces:**
- Produces:
```java
public final class GenomicBlocks {
    public static final List<String> BLOCK_CHANNELS = List.of("sequences","qualities","read_names","cigars","mate_info");
    public record BlockBlobs(Map<String,byte[]> blobs, Map<String,Integer> codecs,
                             Map<String,Map<String,Object>> extraAttrs, int nReads, long nBases) {}
    public static WrittenGenomicRun sliceRun(WrittenGenomicRun run, int start, int stop);
    public static WrittenGenomicRun concatRuns(List<WrittenGenomicRun> parts);
    public static BlockBlobs encodeBlock(WrittenGenomicRun block, GenomicWriteContext ctx);
}
```
`WrittenGenomicRun` gains `boolean optLegacyWholeChannel` (last component; the previous canonical constructor delegates with `false`) and `withOptLegacyWholeChannel(boolean)`.

- [ ] **Step 1: Failing tests** (append to `GenomicBlocksTest`):

```java
@Test
void sliceAndConcatAreInverse() throws Exception {
    WrittenGenomicRun run = m87();                       // 10 reads
    WrittenGenomicRun a = GenomicBlocks.sliceRun(run, 0, 4);
    WrittenGenomicRun b = GenomicBlocks.sliceRun(run, 4, 10);
    assertEquals(4, a.readCount());
    assertEquals(0L, a.offsets()[0]);
    assertEquals(0L, b.offsets()[0]);
    assertEquals(run.lengths()[4], b.lengths()[0]);
    WrittenGenomicRun back = GenomicBlocks.concatRuns(List.of(a, b));
    assertArrayEquals(run.sequences(), back.sequences());
    assertArrayEquals(run.qualities(), back.qualities());
    assertArrayEquals(run.offsets(), back.offsets());
    assertEquals(run.readNames(), back.readNames());
    assertEquals(run.mateChromosomes(), back.mateChromosomes());
}

@Test
void encodeBlockMatchesTheV18WriterBytes() throws Exception {
    WrittenGenomicRun run = m87();
    // A block: the first chromosome's reads only (blocks never span chromosomes).
    String chr = run.chromosomes().get(0);
    int stop = 0; while (stop < run.readCount() && run.chromosomes().get(stop).equals(chr)) stop++;
    WrittenGenomicRun block = GenomicBlocks.sliceRun(run, 0, stop);
    GenomicBlocks.BlockBlobs blobs = GenomicBlocks.encodeBlock(block, new GenomicWriteContext(new LinkedHashMap<>(), null));
    assertEquals(stop, blobs.nReads());
    assertEquals(Enums.Compression.RANS_ORDER0.ordinal(), blobs.codecs().get("cigars"));
    assertEquals(Enums.Compression.FQZCOMP_NX16_Z.ordinal(), blobs.codecs().get("qualities"));
    assertEquals(Enums.Compression.RANS_ORDER1.ordinal(), blobs.codecs().get("sequences")); // no reference
    assertEquals(Enums.Compression.NAME_TOKENIZED_V2.ordinal(), blobs.codecs().get("read_names"));
    assertEquals(Enums.Compression.MATE_INLINE_V2.ordinal(), blobs.codecs().get("mate_info"));
    // Same reads through the v1.8 writer with the same forced overrides give the same bytes.
    Map<String, Enums.Compression> ov = new LinkedHashMap<>();
    ov.put("cigars", Enums.Compression.RANS_ORDER0);
    ov.put("qualities", Enums.Compression.FQZCOMP_NX16_Z);
    ov.put("sequences", Enums.Compression.RANS_ORDER1);
    WrittenGenomicRun same = block.withSignalCodecOverrides(ov);
    StorageGroup root = MemoryProvider.open("memory://gb-cmp", StorageProvider.Mode.CREATE).rootGroup();
    SpectralDatasetGenomicWriter.writeGenomicRunSubtree(root, "r", same, GenomicWriteContext.none());
    StorageGroup sc = root.openGroup("r").openGroup("signal_channels");
    assertArrayEquals((byte[]) sc.openDataset("qualities").readAll(), blobs.blobs().get("qualities"));
    assertArrayEquals((byte[]) sc.openDataset("cigars").readAll(), blobs.blobs().get("cigars"));
    assertArrayEquals((byte[]) sc.openDataset("read_names").readAll(), blobs.blobs().get("read_names"));
    assertArrayEquals((byte[]) sc.openGroup("mate_info").openDataset("inline_v2").readAll(), blobs.blobs().get("mate_info"));
}

@Test
void zeroLengthReadForcesRansQualities() throws Exception {
    WrittenGenomicRun run = m87();
    int z = -1; for (int i = 0; i < run.readCount(); i++) if (run.lengths()[i] == 0) { z = i; break; }
    assumeTrue(z >= 0, "m87 has a SEQ '*' read");
    WrittenGenomicRun block = GenomicBlocks.sliceRun(run, z, z + 1);
    GenomicBlocks.BlockBlobs blobs = GenomicBlocks.encodeBlock(block, new GenomicWriteContext(new LinkedHashMap<>(), null));
    assertEquals(Enums.Compression.RANS_ORDER0.ordinal(), blobs.codecs().get("qualities"));
}
```

- [ ] **Step 2: Run** → compile failure.

- [ ] **Step 3: Implement** `GenomicBlocks` (package `global.thalion.ttio.genomics`, public final, private ctor):

`sliceRun`: `b0 = offsets[start]`, `b1 = offsets[stop-1] + lengths[stop-1]` (0,0 when empty); copy `positions/mappingQualities/flags/lengths/matePositions/templateLengths` ranges with `Arrays.copyOfRange`, `sequences/qualities` `[b0,b1)`, offsets rebased (`offsets[i]-b0`), lists `subList(...)` copied; provenance `List.of()`; every other component from `run` (use the record's canonical constructor).

`concatRuns`: one part → return it; else concatenate arrays, recompute offsets from lengths (`GenomicIndex.offsetsFromLengths`), join lists; other components from `parts.get(0)`; provenance `List.of()`.

`encodeBlock`:
```java
Map<String, Enums.Compression> ov = new LinkedHashMap<>(block.signalCodecOverrides());
ov.putIfAbsent("cigars", Enums.Compression.RANS_ORDER0);
if (!ov.containsKey("qualities")) {
    boolean zero = false; for (int l : block.lengths()) if (l == 0) { zero = true; break; }
    ov.put("qualities", zero ? Enums.Compression.RANS_ORDER0 : Enums.Compression.FQZCOMP_NX16_Z);
}
if (!ov.containsKey("sequences") && block.referenceChromSeqs() == null)
    ov.put("sequences", Enums.Compression.RANS_ORDER1);
WrittenGenomicRun b = block.withSignalCodecOverrides(ov).withProvenance(List.of());
StorageProvider mem = MemoryProvider.open("memory://ttio-block-encode-" + System.identityHashCode(block), StorageProvider.Mode.CREATE);
try {
    StorageGroup root = mem.rootGroup();
    SpectralDatasetGenomicWriter.writeGenomicRunSubtree(root, "b", b, ctx);
    StorageGroup sc = root.openGroup("b").openGroup("signal_channels");
    ... harvest per channel exactly as _blocks.encode_block: sequences → group child "refdiff_v2" or flat "sequences";
        mate_info → group child "inline_v2"; others flat and not a group; absent → empty blob, codec 0.
    harvest(ds) = (bytes = (byte[]) ds.readAll(), codec = ds.hasAttribute("compression") ? ((Number) ds.getAttribute("compression")).intValue() : 0,
                  extra = all other attributes)
} finally { MemoryProvider.discardStore(url); }
```
`nBases` = sum of lengths. `writeGenomicRunSubtree` needs to be reachable from `genomics`: make it `public static` (annotate javadoc "Internal writer entry point; use SpectralDataset.create"). Distinguishing group vs dataset children on a `StorageGroup`: `openGroup` throws for datasets on every provider — write a private `tryGroup(parent, name)` that catches `RuntimeException` and returns null, as Python's `_try_group` does.

`WrittenGenomicRun`: add the component, the delegating constructor, `withOptLegacyWholeChannel`, `withSignalCodecOverrides(Map)`, `withProvenance(List)` (all via the canonical constructor).

- [ ] **Step 4: Run** `mvn -q -B test -Dtest=GenomicBlocksTest` → PASS; `mvn -q -B test -Dtest='GenomicRunTest,ImportExportTest'` → PASS (record change compiles everywhere).

- [ ] **Step 5: Commit** `feat(genomics): block encoder over the v1.8 writer for the blocks_v1 layout`

---

### Task 4: `GenomicStreamWriter`, `LazyReference`, default flip in `SpectralDataset.create`

**Files:**
- Create: `genomics/GenomicStreamWriter.java`, `genomics/LazyReference.java`
- Modify: `SpectralDataset.java` (both genomic-run write sites, lines ~733 and ~1292: route through the stream writer unless `run.optLegacyWholeChannel()`)
- Test: `java/src/test/java/global/thalion/ttio/genomics/GenomicStreamWriterTest.java`, `java/src/test/java/global/thalion/ttio/genomics/LazyReferenceTest.java`

**Interfaces:**
- Produces:
```java
public final class GenomicStreamWriter implements AutoCloseable {
    public static final String LAYOUT = "blocks_v1";
    public static final int DEFAULT_BLOCK_READS = 1_000_000;
    public static final long DEFAULT_BLOCK_BYTES = 256L << 20;
    public static final int CHANNEL_CHUNK = 256 << 10;
    public static final List<CompoundField> INDEX_FIELDS;   // 19 columns, §10.12.2 order
    public record Options(AcquisitionMode acquisitionMode, String referenceUri, String platform, String sampleName,
        Map<String,byte[]> referenceChromSeqs, boolean embedReference, int blockReads, long blockBytes,
        boolean optDisableQualitiesV5, Map<String,Compression> signalCodecOverrides, Compression signalCompression,
        boolean optLegacyWholeChannel, List<ProvenanceRecord> provenanceRecords) {
        public static Options fromRun(WrittenGenomicRun run);       // run-level metadata of a batch
        public Options withBlockPolicy(int reads, long bytes); public Options withLegacy(boolean b);
        public Options withReference(Map<String,byte[]> ref, boolean embed);
    }
    public GenomicStreamWriter(StorageGroup studyGroup, String runName, Options o);
    public void append(AlignedRead read); public void appendBatch(WrittenGenomicRun batch);
    public void flush(); public long readCount(); public int blockCount(); @Override public void close();
}
public final class LazyReference extends AbstractMap<String, byte[]> { public LazyReference(Path fasta); public LazyReference(Path fasta, int cacheChroms); public long lengthOf(String name); }
```

- [ ] **Step 1: Failing tests** — `GenomicStreamWriterTest` (package `global.thalion.ttio.genomics`; helper `study(url)` creates a memory provider root with a `study` group and returns it):

```java
static WrittenGenomicRun m87() throws IOException { /* as in GenomicBlocksTest via BamReader */ }

@Test
void writesBlocksV1LayoutAndIndex() throws Exception {
    WrittenGenomicRun run = m87();                       // 10 reads on 2 chromosomes + unmapped
    StorageGroup study = study("memory://gsw-layout");
    try (GenomicStreamWriter w = new GenomicStreamWriter(study, "genomic_0001",
            GenomicStreamWriter.Options.fromRun(run).withBlockPolicy(4, Long.MAX_VALUE))) {
        w.appendBatch(run);
    }
    StorageGroup rg = study.openGroup("genomic_runs").openGroup("genomic_0001");
    assertEquals("blocks_v1", rg.getAttribute("layout").toString());
    assertEquals(10L, ((Number) rg.getAttribute("read_count")).longValue());
    List<Map<String,Object>> rows = rg.openGroup("blocks").openDataset("index").readRows();
    // chromosome boundaries cut blocks; block_reads=4 cuts within a chromosome
    long total = 0; for (var r : rows) total += ((Number) r.get("n_reads")).longValue();
    assertEquals(10, total);
    for (var r : rows) assertTrue(((Number) r.get("n_reads")).longValue() <= 4);
    assertEquals(19, rows.get(0).size());
    assertTrue(rg.openGroup("signal_channels").openGroup("sequences").hasChild("data"));
    assertTrue(rg.openGroup("genomic_index").hasChild("chromosome_names"));
    assertTrue(rg.openGroup("signal_channels").openGroup("mate_info").hasChild("chrom_names"));
    assertEquals("reads=4,bytes=" + Long.MAX_VALUE, rg.getAttribute("block_policy").toString());
}

@Test
void blocksNeverSpanChromosomes() throws Exception {
    WrittenGenomicRun run = m87();
    StorageGroup study = study("memory://gsw-chrom");
    try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g", GenomicStreamWriter.Options.fromRun(run))) {
        w.appendBatch(run);
    }
    StorageGroup rg = study.openGroup("genomic_runs").openGroup("g");
    List<Map<String,Object>> rows = rg.openGroup("blocks").openDataset("index").readRows();
    short[] ids = (short[]) rg.openGroup("genomic_index").openDataset("chromosome_ids").readAll();
    for (var r : rows) {
        int s = ((Number) r.get("read_start")).intValue(), n = ((Number) r.get("n_reads")).intValue();
        for (int i = s; i < s + n; i++) assertEquals(ids[s], ids[i]);
    }
    assertEquals(new LinkedHashSet<>(run.chromosomes()).size(), rows.size());
}

@Test
void legacyFlagWritesWholeChannelLayout() throws Exception {
    WrittenGenomicRun run = m87();
    StorageGroup study = study("memory://gsw-legacy");
    try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g", GenomicStreamWriter.Options.fromRun(run).withLegacy(true))) {
        w.appendBatch(run);
    }
    StorageGroup rg = study.openGroup("genomic_runs").openGroup("g");
    assertFalse(rg.hasAttribute("layout"));
    assertFalse(rg.hasChild("blocks"));
}

@Test
void appendSingleReadsEqualsBatch() throws Exception {
    WrittenGenomicRun run = m87();
    StorageGroup study = study("memory://gsw-single");
    try (GenomicStreamWriter w = new GenomicStreamWriter(study, "g", GenomicStreamWriter.Options.fromRun(run).withBlockPolicy(3, Long.MAX_VALUE))) {
        for (int i = 0; i < run.readCount(); i++) w.append(readAt(run, i));   // helper builds AlignedRead from arrays
        assertEquals(10, w.readCount());
    }
    assertEquals(10L, ((Number) study.openGroup("genomic_runs").openGroup("g").getAttribute("read_count")).longValue());
}
```
`SpectralDatasetTest`-style test for the default flip (add to `GenomicStreamWriterTest`, HDF5):
```java
@Test
void spectralDatasetCreateWritesBlocksV1ByDefault(@TempDir Path tmp) throws Exception {
    WrittenGenomicRun run = m87();
    Path out = tmp.resolve("d.tio");
    SpectralDataset.create(out.toString(), "t", "", List.of(), List.of(run), List.of(), List.of(), List.of());
    try (Hdf5File f = Hdf5File.open(out.toString(), false)) {   // whichever open the repo's tests use
        Hdf5Group rg = f.rootGroup().openGroup("study").openGroup("genomic_runs").openGroup("genomic_0001");
        assertEquals("blocks_v1", rg.readStringAttribute("layout"));
    }
    Path legacy = tmp.resolve("l.tio");
    SpectralDataset.create(legacy.toString(), "t", "", List.of(), List.of(run.withOptLegacyWholeChannel(true)), List.of(), List.of(), List.of());
    // legacy file has no @layout
}
```
(Check the exact `SpectralDataset.create` overload with genomic runs the existing tests call — `SpectralDatasetTest` has examples — and use that one.)

`LazyReferenceTest`: over `src/test/resources/ttio/fixtures/genomic/m88_test_reference.fa` — `keySet()` equals the `.fai` names, `get(name).length == lengthOf(name)`, bytes equal `ReferenceImport`'s whole-file loader for the same chromosome (find the existing loader used by `RefDiffV2DispatchTest` for that FASTA and compare), a missing name returns null, `containsKey` doesn't load.

- [ ] **Step 2: Run** → compile failure.

- [ ] **Step 3: Implement `LazyReference`** — `AbstractMap<String,byte[]>` over `htsjdk.samtools.reference.IndexedFastaSequenceFile` (create the `.fai` with `htsjdk.samtools.reference.FastaSequenceIndexCreator.create(path, true)` when absent); `entries` from `getIndex()` in file order (`LinkedHashMap<String,Long>` name→length); `get(k)` → LRU (`LinkedHashMap` access-order, `removeEldestEntry` when size > cacheChroms) → `getSequence(name).getBases()` (raw bytes; matches Python which keeps case); `entrySet()` returns an `AbstractSet` whose iterator lazily calls `get` (so the MD5 helper's `sorted(keys)` walk loads one at a time); `containsKey`/`keySet`/`size` from `entries`. `lengthOf(name)`.

- [ ] **Step 4: Implement `GenomicStreamWriter`** — port `stream_writer.py` one to one:
  - `INDEX_FIELDS` built as in Python (`UINT64`, `UINT32`, `UINT64`, `UINT64`, then `<ch>_off/_len` `UINT64` ×5, then `<ch>_codec` `UINT32` ×5).
  - State: `pending` list, `pendingReads`, `pendingBytes`, `pendingChrom`, `chromMap` (`LinkedHashMap<String,Integer>`), `referenceMd5`, `readCount`, `baseCount`, `blockCount`, `rg`, `channelDs` map, `idxDs` map, `indexDs`, `embedded`, `closed`, `legacyParts`.
  - `appendBatch`: as Python (segment by chromosome; flush when the pending chromosome differs; fill by `blockReads`/`blockBytes` with the cumulative-length cut, at least one read; `sliceRun` for partial ranges).
  - `flush`: `concatRuns(pending)`; first time with a reference: `referenceMd5 = SpectralDatasetGenomicWriter.referenceMd5ForRun(applyMeta(block))` (make that helper public static); first time with `embedReference`: `SpectralDatasetGenomicWriter.embedReferencesForRuns(study, List.of(applyMeta(block)))` (public static); `blobs = GenomicBlocks.encodeBlock(applyMeta(block), new GenomicWriteContext(chromMap, referenceMd5))`; `ensureLayout()`; index row `Object[19]` in `INDEX_FIELDS` order (`_off = ds.length()` before append, `_len`, `_codec`); channel datasets created lazily on the first non-empty blob (`sequences` → `sc.createGroup("sequences")` + `data`; `mate_info` → group + `inline_v2`; others flat; `createDataset(name, UINT8, 0, CHANNEL_CHUNK, codec==0 ? ZLIB : NONE, 6, true)`; `@compression` as `(long) codec` — check what attribute type the readers accept: `GenomicRun` reads `((Number) …).intValue()`, and Python reads `int(...)`; the v1.8 writer uses `codecIdFor(...)` which returns an `int` — use the same value type); extra attrs copied; `indexDs.append(List.of(row))`; index arrays appended (`lengths` UINT32 `int[]`, `positions` INT64 `long[]`, `mapping_qualities` UINT8 `byte[]`, `flags` UINT32 `int[]`, `chromosome_ids` UINT16 `short[]` from `chromMap`); counters; `@read_count`/`@base_count` set as `long`.
  - `ensureLayout`: `runsGroup()` (create `genomic_runs` with `@_run_names=""` when absent; append the name to `_run_names`); throw `IllegalArgumentException` if the run exists; run attributes as the v1.8 writer (`acquisition_mode` long ordinal, `modality`, `spectrum_class` 5L, `reference_uri`, `platform`, `sample_name`, `read_count` 0L, `base_count` 0L, `layout`, `block_policy`); `blocks/index` = `createCompoundDataset("index", INDEX_FIELDS, 0, true, 1024)`; `genomic_index/{lengths,positions,mapping_qualities,flags,chromosome_ids}` extendable with `GenomicIndex.CHUNK_SIZE`, ZLIB 6 (make `CHUNK_SIZE`/`COMPRESSION_LEVEL` package-visible constants); empty `signal_channels`.
  - `close`: legacy → `concatRuns(legacyParts)` with meta + provenance, `embedReferencesForRuns` when asked, `SpectralDatasetGenomicWriter.writeGenomicRunSubtree(runsGroup(), name, whole)`; else `flush()`, `ensureLayout()` if never, `writeCloseTables()` (chromosome_names from `chromMap` in id order as `List<Object[]>` VL_STRING rows; `mate_info/chrom_names` when absent), provenance (`provenance/steps` via `Hdf5CompoundIO` when the group unwraps to HDF5, and the `provenance_json` attribute — copy the block at the end of `writeGenomicRunSubtree` into a package-visible static helper `writeRunProvenance(StorageGroup rg, List<ProvenanceRecord>)` and call it from both places).
  - `append(AlignedRead)`: build a one-read `WrittenGenomicRun` (positions `{position}`, mapq, flags, sequence bytes US-ASCII, qualities, offsets `{0}`, lengths `{n}`, cigar, name, mate chrom (`"*"` when null/empty), mate pos, tlen, chromosome) and `appendBatch`.
  - `applyMeta(run)`: canonical-constructor copy setting the option fields from `Options`.
- [ ] **Step 5: `SpectralDataset.create` flip** — at both genomic write sites replace `writeGenomicRunSubtree(gG, gname, gr)` with:
```java
if (gr.optLegacyWholeChannel()) {
    SpectralDatasetGenomicWriter.writeGenomicRunSubtree(gG, gname, gr);
} else {
    try (GenomicStreamWriter w = new GenomicStreamWriter(studyGroup, gname, GenomicStreamWriter.Options.fromRun(gr))) {
        w.appendBatch(gr);
    }
}
```
where `studyGroup` is the `StorageGroup` adapter of the study group at that site (both sites already have `gG` = `genomic_runs`; the writer needs the study group because it manages `genomic_runs` itself and embeds references there — pass the study adapter and let the writer open/create `genomic_runs`; the existing `_run_names` bookkeeping at those sites must not double-add: read the surrounding code and either drop the site's `_run_names` update for stream-written runs or make the writer's `runsGroup()` idempotent — it is (it only appends a missing name)). `embedReferencesForRuns` at the create site: keep it for legacy runs; the writer embeds for its own run.

- [ ] **Step 6: Run** `mvn -q -B test -Dtest='GenomicStreamWriterTest,LazyReferenceTest'` → PASS. Then the whole suite `mvn -q -B test` — expect fallout in tests that open the genomic layout directly (whole-channel dataset names, `signal_channels/sequences` flat, `sequencesFull`, transport bulk mode, signatures, xlang fixture writers). List every failing test; do NOT fix by disabling. Fix rule: a test that asserts the v1.8 layout for its own sake gets `run.withOptLegacyWholeChannel(true)`; a test that reads a run through `GenomicRun` must pass once Task 5 lands (defer those to Task 5, note them). Commit only when the writer tests pass and every other failure is on the Task-5 list.

- [ ] **Step 7: Commit** `feat(genomics): GenomicStreamWriter writes blocks_v1 by default; LazyReference over an indexed FASTA`

---

### Task 5: Reading `blocks_v1` in `GenomicRun`; golden fixture; signatures; transport bulk fallback; suite fallout

**Files:**
- Create: `genomics/BlockTable.java`, `genomics/BlockView.java`
- Modify: `genomics/GenomicRun.java` (layout dispatch, lazy index, `iterReads`, block cache, `layout()`, `blockCount()`, `chromosomeNames()`, bulk-blob accessors return null for multi-block runs, resolver injection)
- Modify: `protection/SignatureManager.java` (`sequences` group children + `blocks/index`)
- Modify: `transport/TransportWriter.java` only if the null-return of the bulk accessors is not already handled (read it: the accessors are documented "returns null when the run has no inline_v2 layout" so the per-AU fallback exists)
- Test: `java/src/test/java/global/thalion/ttio/genomics/GenomicBlocksReaderTest.java`, `java/src/test/java/global/thalion/ttio/genomics/BlocksV1GoldenTest.java`, `ProtectionTest` addition

**Interfaces:**
- Produces: `GenomicRun.iterReads(int start, int stop) : Iterator<AlignedRead>`, `GenomicRun.layout()` (`"blocks_v1"|"whole"`), `GenomicRun.blockCount()`, `GenomicRun.chromosomeNames() : List<String>` (run-level table, no per-read load), package-private `GenomicRun.readFrom(StorageGroup, String, ReferenceResolver)`; `BlockTable.read(StorageGroup runGroup)`, `blockFor(long i)`, `count()`, `readCount()`, column arrays; `BlockView.materialise(StorageGroup runGroup, BlockTable t, int b, List<String> chromNames, List<String> mateChromNames) : StorageGroup` (a `MemoryProvider` group; caller discards the store via the returned `BlockView.Handle` — make `materialise` return a small record `(StorageGroup group, String storeUrl)` and let `GenomicRun` discard the previous store when the cache moves on).

- [ ] **Step 1: Failing tests** — `GenomicBlocksReaderTest`:

```java
static Path writeBlocks(Path tmp, int blockReads) throws Exception {   // HDF5 file via SpectralDataset.create with a run whose writer used blockReads
    WrittenGenomicRun run = m87();
    Path out = tmp.resolve("b" + blockReads + ".tio");
    try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
        StorageGroup study = p.rootGroup().createGroup("study");
        try (GenomicStreamWriter w = new GenomicStreamWriter(study, "genomic_0001",
                GenomicStreamWriter.Options.fromRun(run).withBlockPolicy(blockReads, Long.MAX_VALUE))) { w.appendBatch(run); }
    }
    return out;
}
static SpectralDataset openDs(Path p) { return SpectralDataset.open(p.toString()); }   // whichever open the repo uses; SpectralDataset.open(String) exists

@ParameterizedTest @ValueSource(ints = {1, 3, 1_000_000})
void readsAgreeWithWholeRunDecode(int blockReads, @TempDir Path tmp) throws Exception {
    WrittenGenomicRun run = m87();
    try (SpectralDataset ds = openDs(writeBlocks(tmp, blockReads))) {
        GenomicRun g = ds.genomicRuns().get("genomic_0001");
        assertEquals("blocks_v1", g.layout());
        assertEquals(run.readCount(), g.readCount());
        for (int i = 0; i < run.readCount(); i++) {
            AlignedRead r = g.readAt(i);
            assertEquals(run.readNames().get(i), r.readName());
            assertEquals(run.cigars().get(i), r.cigar());
            assertEquals(run.chromosomes().get(i), r.chromosome());
            assertEquals(run.positions()[i], r.position());
            assertEquals(run.mateChromosomes().get(i).equals("=") ? run.chromosomes().get(i) : run.mateChromosomes().get(i), r.mateChromosome());
            assertEquals(run.matePositions()[i], r.matePosition());
            assertEquals(run.templateLengths()[i], r.templateLength());
            int o = (int) run.offsets()[i], l = run.lengths()[i];
            assertEquals(new String(run.sequences(), o, l, StandardCharsets.US_ASCII), r.sequence());
            assertArrayEquals(Arrays.copyOfRange(run.qualities(), o, o + l), r.qualities());
        }
        int n = 0; Iterator<AlignedRead> it = g.iterReads(0, g.readCount()); while (it.hasNext()) { it.next(); n++; }
        assertEquals(run.readCount(), n);
        List<AlignedRead> region = g.readsInRegion(run.chromosomes().get(0), 0, Long.MAX_VALUE);
        assertFalse(region.isEmpty());
        assertEquals(blockReads >= run.readCount() ? 1 : g.blockCount(), g.blockCount());
    }
}

@Test
void unknownLayoutIsRejected(@TempDir Path tmp) throws Exception {
    Path f = writeBlocks(tmp, 3);
    try (StorageProvider p = ProviderRegistry.open(f.toString(), StorageProvider.Mode.READ_WRITE, "hdf5")) {
        p.rootGroup().openGroup("study").openGroup("genomic_runs").openGroup("genomic_0001").setAttribute("layout", "blocks_v9");
    }
    assertThrows(IllegalStateException.class, () -> openDs(f).genomicRuns());
}

@Test
void partialFileReadsUpToLastBlock(@TempDir Path tmp) throws Exception {
    // write 2 blocks then stop without close: read_count attr lags, index has 2 rows
    WrittenGenomicRun run = m87();
    Path out = tmp.resolve("partial.tio");
    try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
        StorageGroup study = p.rootGroup().createGroup("study");
        GenomicStreamWriter w = new GenomicStreamWriter(study, "genomic_0001", GenomicStreamWriter.Options.fromRun(run).withBlockPolicy(2, Long.MAX_VALUE));
        w.appendBatch(GenomicBlocks.sliceRun(run, 0, 4));   // two blocks flushed
        w.appendBatch(GenomicBlocks.sliceRun(run, 4, 5));   // pending, never flushed; no close()
    }
    // 10.12.5: index and datasets agree up to the last flushed block. The name tables are written
    // at close, so this file is readable through the block table (the whole-run reader needs
    // chromosome_names and is not asserted here).
    try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.READ, "hdf5")) {
        BlockTable t = BlockTable.read(p.rootGroup().openGroup("study").openGroup("genomic_runs").openGroup("genomic_0001"));
        assertEquals(2, t.count()); assertEquals(4, t.readCount());
    }
}
```
`BlocksV1GoldenTest`:
```java
static final Path GOLDEN = Paths.get("..","python","tests","fixtures","genomic","blocks_v1_golden.tio");
static final Path SAM = Paths.get("src","test","resources","ttio","fixtures","genomic","m87_test.sam");

@Test void goldenLayout() {
    assumeTrue(Files.exists(GOLDEN));
    try (SpectralDataset ds = SpectralDataset.open(GOLDEN.toString())) {
        GenomicRun g = ds.genomicRuns().get("genomic_0001");
        assertEquals("blocks_v1", g.layout()); assertEquals(4, g.blockCount()); assertEquals(10, g.readCount());
    }
}
@Test void goldenReadsMatchSourceSam() throws IOException {
    assumeTrue(Files.exists(GOLDEN));
    try (SpectralDataset ds = SpectralDataset.open(GOLDEN.toString())) {
        assertEquals(sam11Md5FromSam(SAM), sam11Md5FromRun(ds.genomicRuns().get("genomic_0001")));
    }
}
// sam11Md5FromSam: non-@ lines, split on \t, first 11 columns, col 7 "=" → col 3; sorted; md5 of "\n".join + "\n"
// sam11Md5FromRun: iterReads → [name|"*", flags, chrom|"*", position, mapq, cigar|"*", mateChrom|"*", matePos, tlen, seq|"*", qual bytes (empty or all 0xFF → "*", else latin-1)] — mirror python/tests/_digests.py exactly (check _md5_lines for the join/terminator).
```
Signature test (add to `ProtectionTest`): sign a `blocks_v1` run (`SignatureManager.signGenomicRun(runGroup, key, "hmac-sha256")`) → map contains `signal_channels/sequences/data`, `signal_channels/qualities`, `blocks/index`; `verifyGenomicRun` true; flip one byte of `sequences/data` via `writeSlice` → false.

- [ ] **Step 2: Run** → compile failure.

- [ ] **Step 3: `BlockTable`** — package-private final class: `long[] readStart, baseStart, nBases; int[] nReads; Map<String,long[]> off, len; Map<String,int[]> codec` (codec null when the column is absent, as Python tolerates); `read(runGroup)` via `runGroup.openGroup("blocks").openDataset("index").readRows()` and `((Number) row.get(...)).longValue()`; `count()`, `readCount()` (last row), `blockFor(long i)` binary search on `readStart` (`Arrays.binarySearch` insertion-point form; throw `IndexOutOfBoundsException` outside range).

- [ ] **Step 4: `BlockView`** — port `materialise_block`: memory root `MemoryProvider.open("memory://ttio-block-view-" + System.identityHashCode(runGroup) + "-" + b, CREATE)`; `view = root.createGroup("run")`; copy run attributes except `layout`,`block_policy`,`base_count`; `read_count = (long) nReads`; `genomic_index` slice: for `(lengths UINT32, positions INT64, mapping_qualities UINT8, flags UINT32, chromosome_ids UINT16)` `src.readSlice(r0, n)` → `dst.createDataset(name, prec, n, 0, NONE, 0)` + `writeAll` + copy attributes; `chromosome_names` compound `[("name", VL_STRING)]` from `chromNames`; signal channels per `BLOCK_CHANNELS`: skip when `len == 0`; codec from the codec column (fallback: source `@compression`); `sequences` → source `signal_channels/sequences/data`; dest `sequences/refdiff_v2` group child when codec == REF_DIFF_V2 ordinal, else flat `sequences`; `mate_info` → source `mate_info/inline_v2`, dest `mate_info/inline_v2`; others flat; `dst.createDataset(name, UINT8, len, 0, NONE, 0)`, `writeAll((byte[]) src.readSlice(off, len))`, copy attributes, then `setAttribute("compression", codec)` with the same value type the v1.8 writer uses; `mate_info/chrom_names` from `mateChromNames` when the source has `mate_info`. Return `record Handle(StorageGroup group, String storeUrl)`.

- [ ] **Step 5: `GenomicRun`** — fields: `index` non-final (`GenomicIndex index` + `Supplier<GenomicIndex> indexLoader`), `String layout = "whole"`, `BlockTable blockTable`, `int cachedBlock = -1`, `GenomicRun cachedView`, `String cachedStoreUrl`, `List<String> chromNamesTable`, `List<String> mateChromNamesTable`, `ReferenceResolver injectedResolver`. `readFrom(runGroup, name)` → `readFrom(runGroup, name, null)`; the 3-arg: `layout = stringAttr(runGroup,"layout","whole")`; `"blocks_v1"` → `blockTable = BlockTable.read(runGroup)`, `index = null`, `indexLoader = () -> GenomicIndex.readFrom(runGroup.openGroup("genomic_index"))`; `"whole"` → today; else `throw new IllegalStateException("genomic run '" + name + "': unsupported layout '" + layout + "' (this reader knows the whole-channel layout and blocks_v1)")`. `index()`: load on demand. `readCount()`: `blockTable != null ? (int) blockTable.readCount() : index.count()`. `chromosomeNames()`: read `genomic_index/chromosome_names` rows (cache). Dispatch in `objectAtIndex`, `readNameAt`, `cigarAt`, `mateChromAt`, `matePosAt`, `mateTlenAt`: `if (blockTable != null) { int b = blockTable.blockFor(i); return blockView(b).<same>(i - (int) blockTable.readStart[b]); }` at the top. `blockView(b)`: cache hit → return; else read name tables once (`chromosomeNames()` and `mate_info/chrom_names` rows), `BlockView.materialise(...)`, `sub = GenomicRun.readFrom(handle.group(), name, resolverForViews())`, discard the previous store (`MemoryProvider.discardStore(cachedStoreUrl)`), cache. `resolverForViews()`: `injectedResolver != null ? injectedResolver : (unwrap runGroup to Hdf5Group → new ReferenceResolver(h5g.owningFile()) : null)`, cached; `codecContext()` uses `resolverForViews()` in place of its inline unwrap. `iterReads(start, stop)`: `Iterator<AlignedRead>` — whole layout: index loop; blocks: walk blocks (`blockFor`), for each block hold the view and yield `view.objectAtIndex(j - r0)`. `nextObject()`/`hasMore()` keep the cursor but read through `objectAtIndex` (block cache makes it one decode per block). `readsInRegion`: unchanged (index load + `objectAtIndex`). `sequencesFull()/qualitiesFull()/readNamesAll()`: under blocks, concatenate over blocks (`ByteArrayOutputStream` of each view's full call). `readRefDiffV2BlobBytes/readNameTokV2BlobBytes/readMateInfoInlineV2BlobBytes`: `if (blockTable != null && blockTable.count() != 1) return null;` else under blocks delegate to `blockView(0)`; whole layout unchanged. `readMateInfoChromNamesTable()` under blocks: the run-level table. `layout()`, `blockCount()` (`blockTable != null ? blockTable.count() : 1`). `close()`: also discard the cached store. Read `transport/TransportWriter.java` at the bulk call site: it must treat a `null` blob as "encode per AU" — it does for the whole-channel absent case; verify the code path with a multi-block run in `TransportEncodeBenchTest`-style test or the existing transport tests (Task 5 fallout list).

- [ ] **Step 6: `SignatureManager`** — in `signGenomicRun`/`verifyGenomicRun`: for each of `sequences`,`qualities`: if `sig.hasChild(c)` and it opens as a group (`tryGroup`) sign every dataset child (`signal_channels/<c>/<child>`), else the flat dataset; after the index columns: `if (runGroup.hasChild("blocks"))` sign `blocks/index` (key `"blocks/index"`). `readCanonicalBytes` on the compound index works through `readRows` + `canonicaliseCompoundRows` (UINT64 handled in Task 1).

- [ ] **Step 7: Run** the three new test classes → PASS. Full suite `mvn -q -B test` → fix the Task-4 fallout list now: tests that read runs through `GenomicRun` pass by themselves; tests that assert on the raw v1.8 dataset names for their own reasons take `withOptLegacyWholeChannel(true)`; xlang fixture writers under `java/src/main/java/global/thalion/ttio/tools/TtioWriteGenomicFixture.java` and any conformance tool: legacy flag until sub-project 4 (mirror the Python pins). Then run the Python conformance matrix that consumes Java: `cd python && .venv/bin/python -m pytest tests/conformance -q -x` and `tests/validation/test_m89_cross_language.py -q` (they build the Java jar; check `python/tests/conformance/conftest.py` for the exact command it runs) → green.

- [ ] **Step 8: Commit** `feat(genomics): read the blocks_v1 layout in GenomicRun; block index in signatures`

---

### Task 6: `FloatDeltaZstd` block API, `SpectralStreamWriter`, lazy `AcquisitionRun` channels

**Files:**
- Modify: `codecs/FloatDeltaZstd.java` (`headerBytes`, `encodeBlock`, `blockBytes`, `BlockTable`, `readBlockTable`, `decodeBlock`, `ByteRangeReader`)
- Create: `SpectralStreamWriter.java`, `WrittenSpectralBatch.java`
- Modify: `AcquisitionRun.java` (lazy channels, `channelRange`, `iterSpectra`, `hasChannel`), `SpectralDataset.java` (no change needed if `readFrom` becomes lazy internally)
- Test: `java/src/test/java/global/thalion/ttio/codecs/FloatDeltaZstdBlockTest.java`, `java/src/test/java/global/thalion/ttio/SpectralStreamWriterTest.java`, `AcquisitionRunLazyChannelsTest.java`

**Interfaces:**
- Produces:
```java
// FloatDeltaZstd
public interface ByteRangeReader { byte[] read(long offset, int count); }
public static byte[] headerBytes(long nValues, int nBlocks);            // 22 bytes, BLOCK_SIZE
public record EncodedBlock(int transform, byte[] body) {}
public static EncodedBlock encodeBlock(double[] values);                 // one block (<= BLOCK_SIZE values)
public static byte[] blockBytes(EncodedBlock b);                         // 5-byte header + body
public record BlockTable(long nValues, int blockSize, int nBlocks, long[] offsets, int[] transforms, int[] lengths) { public int blockValues(int k); }
public static BlockTable readBlockTable(ByteRangeReader r);
public static double[] decodeBlock(ByteRangeReader r, BlockTable t, int k);
// WrittenSpectralBatch
public record WrittenSpectralBatch(long[] offsets, int[] lengths, double[] retentionTimes, int[] msLevels, int[] polarities,
    double[] precursorMzs, int[] precursorCharges, double[] basePeakIntensities,
    int[] activationMethods, double[] isolationTargetMzs, double[] isolationLowerOffsets, double[] isolationUpperOffsets, int[] centroideds,
    Map<String,double[]> channelData) { public int spectrumCount(); public static WrittenSpectralBatch fromRun(AcquisitionRun run, int from, int to); }
// SpectralStreamWriter
public record Options(String spectrumClass, AcquisitionMode acquisitionMode, List<String> channelNames, InstrumentConfig instrumentConfig,
    int batchSpectra, boolean optDisableFloatDelta, Compression signalCompression, String nucleusType, String solvent, List<ProvenanceRecord> provenanceRecords)
public SpectralStreamWriter(StorageGroup studyGroup, String runName, Options o);
public void append(Spectrum s); public void appendBatch(WrittenSpectralBatch b); public void setChromatograms(List<Chromatogram> c);
public void flush(); public int spectrumCount(); @Override public void close();
// AcquisitionRun
public double[] channelRange(String channel, long start, int count);
public Iterator<Spectrum> iterSpectra(int batch); public Iterator<Spectrum> iterSpectra();   // 4096
public boolean hasChannel(String name);
```

- [ ] **Step 1: Failing tests** — `FloatDeltaZstdBlockTest`: `encode(values)` equals `headerBytes(n, nBlocks) + concat(blockBytes(encodeBlock(chunk_k)))` for `n = 3*BLOCK_SIZE + 17` random doubles; `readBlockTable` over the stream gives `nBlocks` entries whose `offsets/lengths` tile the stream; `decodeBlock(k)` equals `decode(stream)` slice `k`. `SpectralStreamWriterTest`: read `src/test/resources/ttio/1min.mzML` (or the small mzML the repo's `MzMLWriterProgressTest` uses) with `MzMLReader.read`, then write it (a) `run.writeTo(msRunsGroup)` and (b) through `SpectralStreamWriter` in batches of 7 (`WrittenSpectralBatch.fromRun(run, i, j)`), both into HDF5 files; assert `spectrum_index/*` arrays equal, `signal_channels/@channel_names` equal, decoded `mz`/`intensity` equal, `@spectrum_count` equal, FDZ1 header `n_values`/`n_blocks` correct (`readBlockTable`), `AcquisitionRun.readFrom` on (b) gives the same `objectAtIndex(i)` values as (a). `AcquisitionRunLazyChannelsTest`: open (a); `channelRange("mz", 5, 40)` equals `channels().get("mz")` slice; `iterSpectra(3)` yields the same spectra as `spectra()`; a run whose `mz_values` dataset is deleted after open still answers `spectrumCount()` (proves nothing was decoded at open — simpler: assert with a `MemoryProvider`-backed run group that `readFrom` does not call `readAll` on the channel dataset: wrap the dataset? Skip; instead assert `readFrom` on a run with a deliberately unknown-codec channel `@compression=99` does NOT throw until `channelRange` is called).

- [ ] **Step 2: Run** → compile failure.

- [ ] **Step 3: `FloatDeltaZstd`** — refactor `encode` to `headerBytes` + per-block `encodeBlock`/`blockBytes` (identical bytes); `readBlockTable(r)`: read 22-byte header (validate magic/version), then walk: `pos = 22; for k: bh = r.read(pos, 5) → transform, len; offsets[k] = pos + 5; lengths[k] = len; transforms[k]; pos += 5 + len`; `decodeBlock`: `planes` inflate of `r.read(offsets[k], lengths[k])`, `untranspose`, delta-undo, to doubles. `decode(stream)` may stay as is.

- [ ] **Step 4: `WrittenSpectralBatch`** + **`SpectralStreamWriter`** — port `spectral_stream_writer.py`: `ensureLayout(first)` (run group attributes as `AcquisitionRun.writeTo`: `acquisition_mode`, `spectrum_count` 0L, `spectrum_class`, `nucleus_type`, `solvent`; `instrument_config` group via the same six attributes `AcquisitionRun.writeInstrumentConfig` writes — make that helper a static package method taking `(StorageGroup, InstrumentConfig)`; `spectrum_index` group with `@count` 0L and extendable columns (`lengths` UINT32, `retention_times` FLOAT64, `ms_levels` INT32, `polarities` INT32, `precursor_mzs` FLOAT64, `precursor_charges` INT32, `base_peak_intensities` FLOAT64; M74 four when the first batch has them; `centroideds` when present) chunk `SpectrumIndex.INDEX_CHUNK_SIZE`, ZLIB 6, extendable; `signal_channels` with `@channel_names` and per channel either an extendable UINT8 dataset with `@compression=17` and the 22-byte placeholder header appended (codec 17 = `signalCompression == FLOAT_DELTA_ZSTD || (ZLIB && !optDisableFloatDelta && "TTIOMassSpectrum".equals(spectrumClass))`) or an extendable FLOAT64 ZLIB dataset); `writeBatch(b)`: backfill logic for M74/centroided as Python; append index columns; per channel FDZ buffering (`double[] fdzBuf`, emit `encodeBlock` on every full `BLOCK_SIZE`, `nValues`/`nBlocks` counters) or plain append; `spectrum_count`/`@count` updated; `close`: emit tail block, `writeSlice(0, headerBytes(nValues, nBlocks))`, chromatograms (`AcquisitionRun.writeChromatograms` made a static helper `(StorageGroup, List<Chromatogram>)`), provenance (`AcquisitionRun.writeProvenance` likewise), `@spectrum_count`, `@total_points` if the v1.8 writer writes it (grep `total_points` — it does not in Java today; skip). `append(Spectrum)`: `MassSpectrum` → one-spectrum batch (mz/intensity; index scalars from the spectrum's getters). `runsGroup()` maintains `ms_runs/@_run_names`.

- [ ] **Step 5: `AcquisitionRun` lazy channels** — replace `private final Map<String,double[]> channels` with `private final Map<String,double[]> eagerChannels` (constructor-supplied, may be empty) plus `private final Map<String,ChannelSource> lazyChannels` where `ChannelSource` (private static final class) holds `StorageGroup sc, String dsName, int codecId, FloatDeltaZstd.BlockTable table, int cachedBlock, double[] cachedValues, double[] full`. `readFrom` fills `lazyChannels` from `@channel_names` (open the dataset, read `@compression`, keep the `StorageDataset` open — the run group is kept open by `readFrom`'s caller? `readFrom` uses try-with-resources on `runGroup`; change it to keep `runGroup` and `sc` open for the run's lifetime and close them in `close()`). `channels()`: for every lazy channel not yet in `full`, decode whole (codec 17 → `decode(readAll)`, else `readAll`) and cache; return an unmodifiable map view of eager+full. `channelRange(name, start, count)`: decrypted overlay → slice; eager → slice; lazy: `full != null` → slice; codec 17 → `readBlockTable` once, block-wise decode with one-block cache; codec 0 → `(double[]) ds.readSlice(start, count)`; unknown codec → `IllegalStateException` (message as today). `objectAtIndex`: use `channelRange` for every slice; `chemShift.length > 0` → `hasChannel("chemical_shift")`. `iterSpectra(batch)`: windows over `spectrumIndex.offsets/lengths`, `channelRange` per channel per window, build spectra with the same code as `objectAtIndex` (factor `buildSpectrum(index, Map<String,double[]> slices)`). `writeTo`/`writeSignalChannels`: iterate `channels()` (materialises when writing an opened run back — same as today). `encryptWithKey`/`decryptWithKey` use `channels()` (check they do; keep). `SpectralDataset.open` needs no change.

- [ ] **Step 6: Run** the three test classes → PASS; then `mvn -q -B test -Dtest='SpectralDatasetTest,ImportExportTest,ProtectionTest,StreamReader*,TransportEncodeBenchTest,MzMLWriter*'` → PASS.

- [ ] **Step 7: Commit** `feat(spectral): SpectralStreamWriter, codec-17 block API and lazy AcquisitionRun channel reads`

---

### Task 7: Streaming importers (BAM/SAM/CRAM, FASTQ, mzML) and `ImportedDataset` streams

**Files:**
- Create: `importers/GenomicStreamSource.java`, `importers/SpectralStreamSource.java`, `importers/BatchAccumulator.java`
- Modify: `importers/BamReader.java` (`iterBatches`, `stream`), `importers/FastqReader.java` (`iterBatches`, `stream`), `importers/MzMLReader.java` (batch callback + `stream`), `importers/ImportedDataset.java` (`genomicStreams`, `spectralStreams`, write-through), `importers/ImporterRegistry.java` (route bam/sam/cram/fastq/mzml), `tools/EncodeCli.java` (extras)
- Test: `java/src/test/java/global/thalion/ttio/importers/StreamingImportersTest.java`

**Interfaces:**
- Produces:
```java
public record GenomicStreamSource(String name, Supplier<Iterator<WrittenGenomicRun>> batches, Path referenceFasta, boolean embedReference,
    Integer blockReads, Long blockBytes, boolean optLegacyWholeChannel) { public long writeInto(StorageGroup study, ProgressSink p); }
public record SpectralStreamSource(String name, Supplier<Iterator<WrittenSpectralBatch>> batches, InstrumentConfig instrumentConfig,
    int batchSpectra, Supplier<List<Chromatogram>> chromatogramsAfter) { public long writeInto(StorageGroup study, ProgressSink p); }
// BamReader
public Iterator<WrittenGenomicRun> iterBatches(String name, String region, String sampleName, int batchReads) throws IOException;
public GenomicStreamSource stream(String name, String region, String sampleName, Path referenceFasta, boolean embedReference, int batchReads);
// FastqReader
public Iterator<WrittenGenomicRun> iterBatches(String sampleName, String platform, String referenceUri, AcquisitionMode mode, int batchReads) throws IOException;
public GenomicStreamSource stream(String name, String sampleName, int batchReads);
// MzMLReader
public static SpectralStreamSource stream(File file, String runName, int batchSpectra, ProgressSink progress);
// ImportedDataset
public final Map<String, GenomicStreamSource> genomicStreams = new LinkedHashMap<>();
public final Map<String, SpectralStreamSource> spectralStreams = new LinkedHashMap<>();
```
Default `batchReads` = 100_000; `batchSpectra` = 4096.

- [ ] **Step 1: Failing tests** — `StreamingImportersTest`:

```java
@Test void bamBatchesConcatenateToTheWholeRun() throws Exception {
    BamReader r = new BamReader(BAM);
    WrittenGenomicRun whole = r.toGenomicRun("g");
    List<WrittenGenomicRun> parts = new ArrayList<>();
    r.iterBatches("g", null, null, 3).forEachRemaining(parts::add);
    assertEquals(4, parts.size());                     // 10 reads / 3
    WrittenGenomicRun back = GenomicBlocks.concatRuns(parts);
    assertEquals(whole.readNames(), back.readNames()); assertArrayEquals(whole.sequences(), back.sequences());
    assertEquals(whole.referenceUri(), parts.get(0).referenceUri());
    assertEquals(r.lastProvenance().size(), parts.get(0).provenanceRecords().size());
}
@Test void fastqBatchesConcatenateToTheWholeRun() throws Exception { /* same shape with FastqReader on the fixture FASTQ used by FastqRoundTrip tests; phred offset detected from the first batch equals detectPhredOffset over the file */ }
@Test void mzmlStreamMatchesWholeRead(@TempDir Path tmp) throws Exception {
    File mz = MZML_FIXTURE;
    AcquisitionRun whole = MzMLReader.read(mz);
    SpectralStreamSource src = MzMLReader.stream(mz, "run_0001", 5, null);
    Path out = tmp.resolve("s.tio");
    try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
        StorageGroup study = p.rootGroup().createGroup("study");
        assertEquals(whole.spectrumCount(), src.writeInto(study, null));
    }
    try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
        AcquisitionRun got = ds.msRuns().get("run_0001");
        assertEquals(whole.spectrumCount(), got.spectrumCount());
        assertArrayEquals(whole.channels().get("mz"), got.channels().get("mz"), 0.0);
        assertEquals(whole.chromatograms().size(), got.chromatograms().size());
    }
}
@Test void importedDatasetWritesStreams(@TempDir Path tmp) throws Exception {
    ImportedDataset d = new ImportedDataset();
    d.genomicStreams.put("genomic_0001", new BamReader(BAM).stream("genomic_0001", null, null, null, false, 3));
    Path out = d.write(tmp.resolve("d.tio"));
    try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
        GenomicRun g = ds.genomicRuns().get("genomic_0001");
        assertEquals("blocks_v1", g.layout()); assertEquals(10, g.readCount());
    }
}
@Test void importerRegistryEncodesBamThroughStreams(@TempDir Path tmp) throws Exception {
    Path out = tmp.resolve("r.tio");
    ImporterRegistry.encode("bam", List.of(BAM.toString()), out, Map.of("block_reads", "3"), null);   // check the real signature
    try (SpectralDataset ds = SpectralDataset.open(out.toString())) { assertEquals("blocks_v1", ds.genomicRuns().values().iterator().next().layout()); }
}
```

- [ ] **Step 2: Run** → compile failure.

- [ ] **Step 3: `BatchAccumulator`** — package-private; the per-record lists from `BamReader.toGenomicRun` (`readNames, chromosomes, positionsL, ...`, `seqChunks`, `qualChunks`, `runningOffset`) with `add(String qname, int flag, String rname, long pos, int mapq, String cigar, String rnext, long pnext, int tlen, byte[] seq, byte[] qual)`, `int size()`, `WrittenGenomicRun toRun(AcquisitionMode mode, String referenceUri, String platform, String sample, List<ProvenanceRecord> prov)` (the array-building tail of `toGenomicRun`), `void clear()`. `BamReader.toGenomicRun` uses it (behaviour unchanged, `lastProvenance` set as before). `iterBatches`: open the reader/header/provenance eagerly (so `referenceUri/platform/sample/provenance` are known for the first batch), return an `Iterator` whose `hasNext` pulls records into the accumulator until `batchReads` or EOF, `next` returns `toRun(...)` and clears; the SAM iterator and reader close at EOF (and in a `finally` if the consumer stops early — implement `AutoCloseable` on the iterator class and close in `hasNext` at EOF). `stream(...)`: `new GenomicStreamSource(name, () -> uncheckedIterBatches(...), referenceFasta, embedReference, null, null, false)`.

`FastqReader.iterBatches`: `iterateRecords` is push-style; restructure into a pull `FastqRecordReader` (`BufferedReader` + `next()` returning `(name, seq, qual)` or null) used by both `read` and `iterBatches`; phred offset: forced or detected on the first batch's concatenated qualities (`detectedPhred` set then); 64 → subtract 31 per batch; `FastaReader.buildUnalignedRun` per batch. `stream(name, sampleName, batchReads)`.

`MzMLReader`: `MzMLHandler` gains an optional `Consumer<WrittenSpectralBatch> sink` and `int batchSpectra`; `finishSpectrum` appends to the accumulators and, when `sink != null && mzArrays.size() == batchSpectra`, calls `sink.accept(drainBatch())` (build offsets from the batch's own arrays; M74 arrays included when `anyActivationDetail`); at `endDocument` the remainder is emitted; `buildRun` unchanged when `sink == null`. `stream(file, runName, batchSpectra, progress)`: returns a `SpectralStreamSource` whose iterator starts a daemon thread running the parser with a `sink` that `put`s into an `ArrayBlockingQueue<Object>(4)` (batches, then a `DONE` sentinel or the caught `Throwable`); `hasNext` takes and rethrows a `Throwable` as `MzMLParseException`/`RuntimeException`; `chromatogramsAfter` returns the handler's list after `DONE`. `writeInto` in `SpectralStreamSource`: as Python (`Options` from the first batch: `spectrumClass "TTIOMassSpectrum"`, `AcquisitionMode.MS1_DDA` for mzML, channel names from `channelData.keySet()`, `instrumentConfig`, `batchSpectra`, ZLIB default, provenance empty; `setChromatograms(chromatogramsAfter.get())` before close).

`GenomicStreamSource.writeInto`: `LazyReference` when `referenceFasta != null`; `Options.fromRun(first).withReference(ref, embed)` + block policy + legacy; `appendBatch` each; count reads.

`ImportedDataset.write`: after the existing create (or a metadata-only create when `runs`/`genomicRuns` are empty and streams are present — `SpectralDataset.create` accepts empty lists), if any stream: `try (StorageProvider p = ProviderRegistry.open(output.toString(), StorageProvider.Mode.READ_WRITE, "hdf5")) { StorageGroup study = p.rootGroup().openGroup("study"); for each genomic stream: writeInto(study, progress); for each spectral: writeInto(study, progress); }`. Check `ProviderRegistry.open`'s signature (`(url, mode, providerName)` per `ProviderTest`).

`ImporterRegistry.encode(...)`: for `bam/sam/cram`, `fastq`, `mzml` build an `ImportedDataset` with a stream instead of the whole read (`extras`: `block_reads`, `block_bytes`, `legacy_whole_channel`, `reference`, `embed_reference`, `sample`, `region`, `batch_reads`); the FASTA delegated path is unchanged. `EncodeCli` documents the extras in usage.

- [ ] **Step 4: Run** `StreamingImportersTest` + `BamReaderTest`, `FastqRoundTrip*`, `ImporterRegistryTest`, `ImportExportTest` → PASS.

- [ ] **Step 5: Commit** `feat(importers): stream BAM/SAM/CRAM, FASTQ and mzML through the stream writers`

---

### Task 8: Streaming exporters (SAM/BAM, FASTQ, mzML)

**Files:**
- Modify: `exporters/BamWriter.java` (`write(GenomicRun run, provenance, sort, sink)`), `exporters/CramWriter.java` (inherits), `exporters/FastqWriter.java` (`GenomicRun` overload uses `iterReads`), `exporters/MzMLWriter.java` (stream to `OutputStream`, `iterSpectra`), `exporters/writers/BamWriterAdapter.java`, `CramWriterAdapter.java` (call the `GenomicRun` overload), `exporters/RunSelection.java` (`toWritten` stays for callers)
- Test: `java/src/test/java/global/thalion/ttio/exporters/StreamingExportersTest.java`

**Interfaces:**
- Produces: `BamWriter.write(GenomicRun run, List<ProvenanceRecord> provenance, boolean sort, ProgressSink sink)`; `FastqWriter.write(GenomicRun run, Path, Boolean gz, int phred, ProgressSink)` (existing signature, streaming body); `MzMLWriter.write(AcquisitionRun run, String path, boolean zlib, ProgressSink)` (existing signature, streaming body).

- [ ] **Step 1: Failing tests** — `StreamingExportersTest`: build a 3-read-block `.tio` from m87 (as Task 5's `writeBlocks`), open it, `new BamWriter(out.bam).write(g, ds.provenanceRecords(), true, null)`, then `sam11Md5FromSam(samtools-free: read back the BAM with htsjdk SamReader and build the 11 columns)` equals the m87 digest (reuse Task 5's helper against `m87_test.sam`); FASTQ: `FastqWriter.write(g, out.fq, false, 33, null)` → triple digest equals a `FastqWriter.write(RunSelection.toWritten(g), ...)` output byte-for-byte; mzML: `MzMLWriter.write(run, out.mzML, true, null)` on the mzML fixture round-tripped through `SpectralStreamWriter` equals (byte-for-byte) the output of the same call on the eager run — the writer output must not change.

- [ ] **Step 2: Run** → compile failure / assertion.

- [ ] **Step 3: Implement** — `BamWriter.write(GenomicRun ...)`: header from `run.chromosomeNames()` (same `@SQ LN` placeholder as `buildHeader`), `@RG` from `sampleName/platform`, `@PG` from provenance (factor `buildHeader` to take `(List<String> chromosomes, String sample, String platform, provenance)`); `buildSamRecord(AlignedRead r, header)` (same field rules; `qualities` all `0xFF` → `NULL_QUALS`); iterate `run.iterReads(0, n)` and `writer.addAlignment(rec)`; progress every 1000. `FastqWriter.write(GenomicRun ...)`: replace the `sequencesFull/qualitiesFull/readNamesAll` prefetch by `iterReads` writing through a `BufferedOutputStream` (gzip when asked); keep the duplicate-name `seen` set (it exists today) — note it is O(n) memory in names; keep as is (unchanged behaviour). `MzMLWriter`: replace the `StringBuilder` by a `CountingOutputStream` wrapper over `BufferedOutputStream(FileOutputStream)`; every `sb.append(...)` becomes `w.write(...)`; the offsets for the `indexList` are the counted byte position at each `<spectrum` and `<chromatogram` start (the current code computes them from `sb.length()` — check the encoding: use UTF-8 byte counts, which the current `sb.length()` only equals for ASCII; keep semantics identical by writing ASCII-only content as today); the SHA-1 checksum footer needs the bytes written so far — feed the counting stream through a `MessageDigest` (`DigestOutputStream`) up to the `<fileChecksum>` tag exactly as the current implementation hashes the builder's prefix; spectra via `run.iterSpectra()`; `spectrumList count` from `run.spectrumCount()`. Adapters call the `GenomicRun` overloads.

- [ ] **Step 4: Run** the new test + `MzMLWriterProgressTest`, `BamWriterProgressTest`, `CramBamRoundTripTest`, `FastqWriterProgressTest`, `FormatWritersTest`, `ExporterRegistryTest` → PASS. Full suite → PASS.

- [ ] **Step 5: Commit** `feat(exporters): stream SAM/BAM, FASTQ and mzML export from block and range readers`

---

### Task 9: tio-browser `ImportTask` streams

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/importers/ImportTask.java` (BAM/SAM/CRAM and FASTQ through `stream(...)` + `ImportedDataset.genomicStreams`)
- Test: tio-browser has TestFX tests that hang headless ([[feedback_tio_browser_testfx_render_hang]]); add a plain JUnit test `ImportTaskStreamingTest` only if a headless-safe unit test exists for `ImportTask` today; otherwise verify by `mvn -q -B -pl tio-browser compile` and a manual import in the next session.

- [ ] **Step 1:** Read `ImportTask` lines 180-240 (`importBam`/`importFastq`/`writeGenomic`): replace `r.toGenomicRun(...)`/`r.read(...)` + `writeGenomic(List<WrittenGenomicRun>)` with `draft.genomicStreams.put(config.runName, reader.stream(...))` and `draft.write(config.targetTio, writerSink)`; progress: the readers' batch iterators report through `readerSink` per batch (`GenomicStreamSource.writeInto` calls `progress.onProgress(readsSoFar, -1)` after each batch and `(n, n)` at the end).
- [ ] **Step 2:** tio-browser depends on the SDK jar in `tio-browser/local-repo`: run `cd java && mvn -q -B install -DskipTests` then `cd ../tio-browser && mvn -q -B compile` (check `tio-browser/README.md` for the exact install step it expects) → compiles.
- [ ] **Step 3: Commit** `feat(tio-browser): stream BAM and FASTQ imports`

---

### Task 10: Docs, CHANGELOG, format-spec cross-reference

**Files:**
- Modify: `java/README.md` (streaming section: `GenomicStreamWriter`, `SpectralStreamWriter`, `iterReads`/`iterSpectra`, encode extras), `ARCHITECTURE.md` (Java entry in the streaming/blocks section if one exists; else a short paragraph next to the Python one), `CHANGELOG.md` (Unreleased: Java writes `blocks_v1` by default, reads both layouts, streaming importers/exporters, provider extendable datasets and UINT64), `docs/format-spec.md` §10.12.6 already names the Java class — verify the name matches (`GenomicStreamWriter`), `docs/superpowers/specs/2026-08-17-streaming-blocks-v1-java-design.md` status note (implemented; note the two deviations: SQLite append is read-modify-write and Zarr append rewrites, both as Python does; extendable compound datasets are primitive-kind only).
- [ ] **Step 1:** Write the sections in the repo's register (plain statements; no marketing).
- [ ] **Step 2:** Run the attribution/style gate on the diff (`git diff main --stat`, `git log --format=%B main..HEAD | rg -i "claude|anthropic|generated with|co-authored"` → nothing).
- [ ] **Step 3: Commit** `docs: Java streaming import/export and blocks_v1`

---

### Task 11: Memory ceiling check and a Java-written blocks_v1 file opened by Python

**Files:**
- Test: `java/src/test/java/global/thalion/ttio/genomics/StreamingMemoryTest.java` (tag `@Tag("slow")`; JUnit `@EnabledIfSystemProperty(named="ttio.slow", matches="true")`)
- Test: `python/tests/conformance/test_blocks_v1_java_written.py`

- [ ] **Step 1:** `StreamingMemoryTest`: generate a 2 M-read synthetic FASTQ (100 bp, deterministic RNG) into a temp file, `FastqReader.stream(...)` → `ImportedDataset.write`; assert `Runtime.getRuntime().totalMemory()` peak sampled by a daemon thread stays under 1.5 GB with `-Xmx2g` (set via `argLine` for the slow profile only — check `pom.xml`'s surefire `argLine`; add `-Xmx2g` only when `ttio.slow`); assert the file opens and `readCount() == 2_000_000`.
- [ ] **Step 2:** `test_blocks_v1_java_written.py`: skip unless `mvn` and the Java jar build are available the way `python/tests/conformance/conftest.py` already does for the xlang matrix (reuse its helper that runs a Java tool); run `TtioWriteGenomicFixture` (extend that tool with a `--blocks` flag writing the m87 BAM through `GenomicStreamWriter` with `blockReads=3` to a temp path — check its current CLI shape and add the flag), open the result in Python, assert `layout == "blocks_v1"`, `block_count == 4`, and `genomic_run_sam11_md5(g) == sam11_md5(m87 BAM)`.
- [ ] **Step 3:** Run both (`mvn -q -B test -Dtest=StreamingMemoryTest -Dttio.slow=true`; `cd python && .venv/bin/python -m pytest tests/conformance/test_blocks_v1_java_written.py -q`) → PASS.
- [ ] **Step 4: Commit** `test: Java streaming memory ceiling; Python reads a Java-written blocks_v1 file`

---

### Task 12: Full suites and PR

- [ ] **Step 1:** `cd java && mvn -q -B test` → 0 failures. `cd python && .venv/bin/python -m pytest -q -x` (the Python suite includes the conformance/xlang cells that build Java) → green. ObjC untouched.
- [ ] **Step 2:** `git log --oneline main..HEAD`; attribution/style gate on every commit body and on the PR body draft (`--body-file`, then `rg` the live PR body after creation — [[feedback_no_llm_style_tells_oss]]).
- [ ] **Step 3:** Push via Windows git ([[feedback_git_push_via_windows]]) and open the PR: title `feat: streaming import/export and the blocks_v1 genomic layout (Java)`, body: 5 parts under 200 words linking spec and plan; not a draft. Watch the 11 checks; a red `objc-py-REFERENCES` cell is the known intermittent SIGSEGV → `gh run rerun --failed`.
- [ ] **Step 4:** Update memory `project_ttio_streaming_blocks_v1` with the PR number, CI rounds and any layout fact learned; then wait for Todd's merge go.

## Self-review

- Spec coverage: §3 → Task 1; §4 → Tasks 2–3; §5 → Task 4; §6 → Task 5; §7 → Task 6; §8 → Task 7; §9 → Task 8; §10 → Task 9; §11 → Tasks 1–8, 11; §12 → Tasks 4, 10; §13 risks → Task 2 (memory-provider round trip first), Task 1 (VL extendable documented as unsupported), Task 4/11 (MD5 parity via the golden fixture and the Python-reads-Java test), Task 7 (producer thread).
- Names used consistently: `GenomicWriteContext`, `GenomicBlocks.{sliceRun,concatRuns,encodeBlock,BLOCK_CHANNELS,BlockBlobs}`, `GenomicStreamWriter.Options.{fromRun,withBlockPolicy,withLegacy,withReference}`, `BlockTable.{read,blockFor,count,readCount}`, `BlockView.materialise`, `GenomicRun.{iterReads,layout,blockCount,chromosomeNames}`, `FloatDeltaZstd.{headerBytes,encodeBlock,blockBytes,readBlockTable,decodeBlock,ByteRangeReader}`, `WrittenSpectralBatch`, `SpectralStreamWriter`, `AcquisitionRun.{channelRange,iterSpectra,hasChannel}`, `GenomicStreamSource`, `SpectralStreamSource`, `BatchAccumulator`.
