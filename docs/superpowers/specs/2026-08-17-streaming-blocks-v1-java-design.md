# Streaming import/export and `blocks_v1` in Java (sub-project 2)

> **Status (2026-08-17).** Implemented on branch
> `streaming-blocks-v1-java` (plan
> `docs/superpowers/plans/2026-08-17-streaming-blocks-v1-java.md`).
> Deviations from the text below: SQLite `append` is read-modify-write
> of the single blob and Zarr `append` rewrites the array (both as the
> Python providers do); extendable compound datasets on HDF5 take
> primitive kinds only; the transport per-spectrum path reads channel
> ranges (`channelRange`) instead of whole channels. Design for the Java implementation of
> `docs/format-spec.md` section 10.12 and of streaming import/export.
> Sub-project 2 of 4; sub-project 1 (format + Python) merged as
> PR #290. The format contract is section 10.12; the Python design is
> `docs/superpowers/specs/2026-08-16-streaming-blocks-v1-design.md`
> and its code is the reference for every class named below. The
> decode contract is `python/tests/fixtures/genomic/blocks_v1_golden.tio`.

> **Out of scope:** Objective-C (sub-project 3); un-pinning the
> cross-language fixtures from `opt_legacy_whole_channel=True` and the
> `GENOMIC_RUNS_BLOCKS` matrix cell (sub-project 4, needs ObjC too);
> any codec wire change; per-AU/region encryption of genomic channels
> (whole-channel layout only, unchanged).

## 0. Why

Every Java importer builds a whole `WrittenGenomicRun` or
`AcquisitionRun` in memory and every genomic channel is one blob per
run; `SpectralDataset.open` decodes every MS channel of every run into
`double[]` before returning. A whole-genome BAM or a large mzML cannot
be imported, opened, or exported on an ordinary machine. Python now
streams both directions and writes genomic runs as `blocks_v1`; a
`blocks_v1` file is unreadable by Java today (`GenomicRun.readFrom`
looks for whole-channel datasets that are not there). Java must read
the layout, write it by default, and stream import/export the same
way, so that the three implementations stay interchangeable.

## 1. Goals and non-goals

Goals:

1. `GenomicRun` reads `blocks_v1` runs (the golden fixture and every
   Python-written file) with one decoded block resident, and still
   reads the v1.8 whole-channel layout.
2. `GenomicStreamWriter` writes `blocks_v1` with bounded memory;
   `SpectralDataset.create` and every genomic write path emit
   `blocks_v1` by default, `optLegacyWholeChannel` restores v1.8.
3. `SpectralStreamWriter` writes MS runs with bounded memory (no
   layout change); `AcquisitionRun` reads channel ranges without
   decoding whole channels.
4. All four Java providers support extendable datasets and the
   `UINT64` compound field kind.
5. BAM/SAM/CRAM, FASTQ and mzML importers stream into the writers;
   SAM/BAM, FASTQ and mzML exporters stream out of the readers; the
   CLI tools and tio-browser use the streaming paths.
6. Java tests mirror the Python ones; the Java suite stays green; the
   Python cross-language conformance suite stays green (fixtures still
   pinned to legacy).

Non-goals: Thermo/Bruker/Waters vendor importers (Java delegates them
to external converters that already produce whole files; unchanged);
multi-threaded encode; a finer region index; changing
`AcquisitionRun`'s public eager accessors (`channels()`, `spectra()`)
— they stay and load on demand.

## 2. Format contract (normative elsewhere)

Everything Java writes and reads is defined by format-spec 10.12:
`@layout="blocks_v1"`, `@block_policy`, `blocks/index` compound with
the fixed 19-column order (`read_start u64, n_reads u32, base_start
u64, n_bases u64, <ch>_off/<ch>_len u64 x5, <ch>_codec u32 x5`, channel
order `sequences, qualities, read_names, cigars, mate_info`),
`signal_channels/sequences/data` (always a group), `qualities`,
`read_names`, `cigars`, `mate_info/inline_v2` as extendable unfiltered
`uint8` datasets (256 KiB chunks; codec 0 keeps zlib), blocks never
spanning chromosomes, the forced codecs (cigars RANS_ORDER0, qualities
FQZCOMP_NX16_Z or RANS_ORDER0 for a block with a zero-length read,
sequences REF_DIFF_V2 with a reference else RANS_ORDER1), run-level
`genomic_index/chromosome_names` and `mate_info/chrom_names` from one
shared first-seen map written at close, `@read_count`/`@base_count`
updated per flush, extendable `genomic_index/*` arrays (no `offsets`
on disk), unknown `@layout` is an error. Java adds nothing to the
format. Where this document and 10.12 differ, 10.12 wins.

## 3. Providers: extendable datasets and `UINT64`

`StorageGroup` gains overloads (defaults keep every existing caller
compiling):

```java
StorageDataset createDataset(String name, Precision p, long length,
        int chunkSize, Compression c, int level, boolean extendable);
StorageDataset createCompoundDataset(String name, List<CompoundField> f,
        long count, boolean extendable, int chunkRows);
```

`StorageDataset` gains:

```java
default boolean extendable() { return false; }
void append(Object data);                 // grows length by data.length / rows
void writeSlice(long offset, Object data); // in-place overwrite, no growth
```

`extendable=true` requires `chunkSize > 0` (`IllegalArgumentException`
otherwise); `append` on a non-extendable dataset throws
`UnsupportedOperationException`. `length()`/`shape()` reflect appended
data immediately.

| provider | mechanism |
|---|---|
| hdf5 | create with `maxdims = {H5S_UNLIMITED}` and a chunk even when `length == 0` (today `Hdf5Group.createDataset` skips the chunk plist when `length == 0`); `append` = `H5Dset_extent` + hyperslab `H5Dwrite`; `writeSlice` = hyperslab write. `Hdf5Dataset.length` becomes mutable and is refreshed from `H5Dget_space` on open. Compound: same via `Hdf5CompoundIO` with a chunked, unlimited dataspace and a hyperslab write per appended row batch (primitive and VL columns as today, split-write path). |
| zarr | rewrite `zarr.json` shape and write only the chunks the appended range touches (v3 chunk grid already in `ZarrProvider`); compound arrays stay the existing JSON-rows encoding, appended by rewrite (small: the block index). |
| memory | `MemDataset` holds a growable buffer per precision (or a `List<Map>` for compound); `append` concatenates. |
| sqlite | one row per appended chunk in a new `dataset_chunks(dataset_id, seq, data)` table; `readSlice` walks rows; non-extendable datasets keep the single-blob column. Compound append rewrites the row list (small). |

`CompoundField.Kind` gains `UINT64` (Java `long`; HDF5
`H5T_NATIVE_UINT64`; canonical bytes 8-byte little-endian like
`INT64`; SQLite/Zarr/Memory store it as a `long`). `Hdf5Provider`'s
member-type inference maps an 8-byte unsigned integer member to
`UINT64` and a signed one to `INT64` (today every 8-byte integer reads
as `INT64`; that stays correct for reading, and the block index values
never exceed 2^63).

Tests: `ProviderTest` gains an extendable round trip on all four
providers (append 3 batches, `readSlice` across batch boundaries,
`writeSlice` in place, `length()` after each), an extendable compound
round trip with `UINT64`, and the error cases.

## 4. Block encoder: `genomics/GenomicBlocks`

Package-private final class, the Java twin of `ttio.genomic._blocks`:

```java
static final List<String> BLOCK_CHANNELS = List.of("sequences","qualities","read_names","cigars","mate_info");
record BlockBlobs(Map<String,byte[]> blobs, Map<String,Integer> codecs,
                  Map<String,Map<String,Object>> extraAttrs, int nReads, long nBases) {}
static WrittenGenomicRun sliceRun(WrittenGenomicRun run, int start, int stop);
static WrittenGenomicRun concatRuns(List<WrittenGenomicRun> parts);
static BlockBlobs encodeBlock(WrittenGenomicRun block, GenomicWriteContext ctx);
```

`encodeBlock` applies the forced-codec rules of 10.12.3 to
`signalCodecOverrides` (cigars → RANS_ORDER0; qualities →
FQZCOMP_NX16_Z, or RANS_ORDER0 when any `lengths[i] == 0`; sequences →
RANS_ORDER1 when `referenceChromSeqs == null`), writes the block
through the existing `SpectralDatasetGenomicWriter.writeGenomicRunSubtree`
into a `MemoryProvider` root, and harvests each channel dataset's
bytes, `@compression` and remaining attributes (`sequences/refdiff_v2`
or flat `sequences`; `mate_info/inline_v2`; flat `qualities`,
`read_names`, `cigars`). A block's blob is therefore byte-identical to
a v1.8 whole-run write of those reads, which is the whole
cross-language contract.

`GenomicWriteContext` is a new package-private record threaded into
`writeGenomicRunSubtree` (new overload; the existing signature calls
it with an empty context):

```java
record GenomicWriteContext(Map<String,Integer> chromNameToId,   // shared, grows in place; null = per-run
                           byte[] referenceMd5) {}                // precomputed; null = compute
```

`GenomicIndex.writeTo` and `writeMateInfoV2` take the shared map when
present (ids stable across blocks, map extended in place, exactly as
Python's `name_to_id`), and `writeSequencesRefDiff` uses the
precomputed MD5. This is a context parameter rather than two new
`WrittenGenomicRun` record components because the record already has
six constructors and the values are writer state, not run data.

`writeGenomicRunSubtree` must not touch HDF5-specific handles on this
path: the only unwrap in it is the per-run provenance writer, and a
block carries no provenance (`encodeBlock` writes the block with
`provenanceRecords = List.of()`).

## 5. `genomics/GenomicStreamWriter`

```java
public final class GenomicStreamWriter implements AutoCloseable {
    public static final int DEFAULT_BLOCK_READS = 1_000_000;
    public static final long DEFAULT_BLOCK_BYTES = 256L << 20;
    public GenomicStreamWriter(StorageGroup studyGroup, String runName, Options o);
    public void append(AlignedRead read);
    public void appendBatch(WrittenGenomicRun batch);   // run-level metadata of the batch is ignored
    public void flush();                                 // encode + write the pending block
    public long readCount(); public int blockCount();
    @Override public void close();                       // flush, name tables, provenance
}
public record Options(AcquisitionMode acquisitionMode, String referenceUri, String platform,
        String sampleName, Map<String,byte[]> referenceChromSeqs, boolean embedReference,
        int blockReads, long blockBytes, boolean optDisableQualitiesV5,
        Map<String,Compression> signalCodecOverrides, Compression signalCompression,
        boolean optLegacyWholeChannel, List<ProvenanceRecord> provenanceRecords) { /* builder */ }
```

Behaviour, line for line with `stream_writer.py`:

- `appendBatch` splits the batch at chromosome changes and flushes the
  pending block whenever the next segment's chromosome differs; within
  a segment it fills the pending block up to `blockReads` reads or
  `blockBytes` sequence bytes (whichever first, at least one read per
  block) using `sliceRun`.
- `flush` concatenates the pending parts, computes the reference MD5
  once (first flush with a reference), embeds the reference once
  (`embedReferencesForRuns` on the study group, first flush, when
  `embedReference`), encodes through `GenomicBlocks.encodeBlock`, lazily
  creates the run group and layout on the first block (`@layout`,
  `@block_policy`, `blocks/index` extendable compound with 1024-row
  chunks, extendable `genomic_index/{lengths,positions,mapping_qualities,flags,chromosome_ids}`
  with the default signal chunk and zlib, empty `signal_channels`),
  creates a channel dataset on its first non-empty blob (`sequences/data`
  group form; `mate_info/inline_v2`; flat otherwise; 256 KiB chunks;
  unfiltered unless codec 0), appends the blobs, appends the index
  row, appends the index arrays (`chromosome_ids` from the shared
  map), and updates `@read_count`/`@base_count`.
- `close` flushes, creates the layout if no block was ever written,
  writes `genomic_index/chromosome_names` and (when absent)
  `mate_info/chrom_names` from the shared map in id order, writes
  provenance under `provenance/steps` when records were given, and
  maintains `genomic_runs/@_run_names` (creating the group when
  absent).
- `optLegacyWholeChannel=true` buffers every batch and calls the v1.8
  writer at close (memory-unbounded by definition).

`SpectralDataset.create(...)` writes each `WrittenGenomicRun` through
`GenomicStreamWriter.appendBatch` unless the run's new
`optLegacyWholeChannel` flag is set (one new record component with a
delegating constructor, default `false`; Python has the same field);
`SpectralDatasetGenomicWriter.writeGenomicRunSubtree` stays the v1.8
writer used by the legacy path and by the block encoder.

`genomics/LazyReference implements Map<String,byte[]>` over an indexed
FASTA through htsjdk (`IndexedFastaSequenceFile`; creates the `.fai`
with `FastaSequenceIndexCreator` when absent), LRU of two chromosomes;
`keySet()`/`containsKey()` from the index without loading, `get()`
loads. It is what the streaming BAM importer passes as
`referenceChromSeqs`; the MD5 helper iterates the sorted keys once, so
each chromosome is loaded once and dropped.

## 6. Reading `blocks_v1`: `GenomicRun`

`GenomicRun.readFrom(StorageGroup runGroup, String name)` reads
`@layout`:

- absent → today's path (eager `GenomicIndex`), unchanged;
- `"blocks_v1"` → reads `blocks/index` into a `BlockTable`
  (package-private, columns as `long[]`/`int[]`, `blockFor(i)` by
  binary search on `read_start`, `readCount()` from the last row) and
  builds the run with a lazy index;
- anything else → `IllegalStateException("unsupported layout ...")`.

The lazy index: `GenomicRun.index()` keeps returning a `GenomicIndex`;
under `blocks_v1` it is loaded from `genomic_index/` on first call
(`readCount()` comes from the block table and does not trigger the
load; `readsInRegion`, `ChromDistributionView` and the like do, which
is today's cost). `GenomicIndex.readFrom` already derives `offsets`
from `lengths` when the dataset is absent.

Block view (`genomics/BlockView`, package-private, twin of
`_block_view.py`): `materialise(runGroup, table, b, nameTables)`
builds a v1.8-shaped run group in a `MemoryProvider` root: run
attributes minus `layout`/`block_policy`/`base_count`, `@read_count =
n_reads`, the `genomic_index` slice with attributes and the run-level
`chromosome_names`, each non-empty channel blob under its v1.8 name
(`sequences/refdiff_v2` when the codec column says REF_DIFF_V2, flat
`sequences` otherwise; `mate_info/inline_v2`; flat others) with the
source dataset's attributes and `@compression` from the codec column,
and `mate_info/chrom_names` from the run-level table. `GenomicRun`
opens a `GenomicRun` over that view through a package-private
`readFrom(StorageGroup, String, ReferenceResolver)` so the view
shares the parent's resolver (built once from the owning `Hdf5File`;
`ReferenceResolver` cannot be built from a memory group). One block
view is cached (last block); the name tables are read once per run.

Dispatch: `objectAtIndex`, `readNameAt`, `cigarAt`, `mateChromAt`,
`matePosAt`, `mateTlenAt` map `i` to `(block, i - read_start)` and
delegate to the view. New `Iterator<AlignedRead> iterReads(int start,
int stop)` walks blocks in order holding one view; `nextObject`/the
`Streamable` cursor use it. `readsInRegion` uses the index as today and
resolves hits through the block dispatch. `sequencesFull`,
`qualitiesFull`, `readNamesAll` concatenate over blocks (whole-run by
definition; used by the legacy exporter paths, which move to
`iterReads`). `readRefDiffV2BlobBytes`, `readNameTokV2BlobBytes`,
`readMateInfoInlineV2BlobBytes` return the blob only for a one-block
run and `null` otherwise, so `TransportWriter`'s bulk BlobV2 carriage
falls back to per-AU encoding for multi-block runs (Python does the
same).

`codecContext()` already derives own chromosome ids from the
`mate_info/chrom_names` row index; the block view carries the run-level
table, so the mate decode of a block is correct as is. `layout()`
and `blockCount()` accessors are added for tests and tio-browser.

`SignatureManager.signGenomicRun`/`verifyGenomicRun` sign the same
set as Python (`sequences`, `qualities`, the seven index columns):
when `sequences` is a group they sign the datasets inside it
(`sequences/refdiff_v2` for a whole-channel run, `sequences/data` for
`blocks_v1`), and they add `blocks/index` (canonical compound bytes,
`UINT64` as 8-byte LE) when present.

## 7. Spectral streaming

### 7.1 `codecs/FloatDeltaZstd` block API

Alongside `encode`/`decode`: `headerBytes(nValues, nBlocks)`,
`encodeBlock(double[] values) -> (transform, body)`,
`blockBytes(transform, body)`, `BlockTable readBlockTable(ByteRangeReader)`
(header + per-block `(offset, transform, length)` walked from the
stream without reading bodies), `double[] decodeBlock(ByteRangeReader,
BlockTable, k)`. `ByteRangeReader` is `(long off, int n) -> byte[]`
over `StorageDataset.readSlice`. Same bytes as today's `encode`.

### 7.2 `SpectralStreamWriter`

```java
public final class SpectralStreamWriter implements AutoCloseable {
    public SpectralStreamWriter(StorageGroup studyGroup, String runName, Options o);
    public void append(Spectrum s); public void appendBatch(WrittenSpectralBatch b);
    public void setChromatograms(List<Chromatogram> c);
    public void flush(); @Override public void close();
}
```

`WrittenSpectralBatch` is a small record (offsets, lengths, per-spectrum
index columns as arrays, `Map<String,double[]> channelData`) — the Java
twin of Python's `WrittenRun` batch, produced by the importers. First
`appendBatch` creates the run group with today's attributes
(`AcquisitionRun.writeTo` layout: `spectrum_index/*`,
`signal_channels/<c>_values`, `@channel_names`, instrument config), all
per-spectrum datasets extendable; each batch appends index columns and,
per channel, either appends doubles (codec 0 / numpress unchanged) or
buffers values and emits FDZ1 blocks as each 2^20-value block fills
(the header is written first as a placeholder). `close` emits the tail
block, rewrites the FDZ1 header via `writeSlice(0, headerBytes(...))`,
writes `@spectrum_count`/`@total_points`, chromatograms and provenance.
A file it writes is what `AcquisitionRun.writeTo` would write except
for chunk allocation, so `readFrom` and every MS reader open it
unchanged. The existing `StreamWriter` (whole-file regenerative flush)
keeps its API and behaviour.

### 7.3 `AcquisitionRun` lazy channels

`readFrom` stops decoding channels; it records per channel the dataset
name and codec id and keeps the run group open (the provider group is
already the run's lifetime object). New:

```java
public double[] channelRange(String channel, long start, int count);
public Iterator<Spectrum> iterSpectra(int batch);      // default 4096
```

`channelRange` slices a decrypted/numpress overlay when present, else
for codec 17 decodes only the FDZ1 blocks the range covers (one-block
cache per channel), else `readSlice`. `channelSlice(name, i)` and
`objectAtIndex` go through `channelRange`; `channels()` and
`spectra()` keep their contract by loading on first call (decoding
whole channels once and caching, which is today's behaviour deferred
to the caller who asks for it). `SpectralDataset.open` therefore no
longer decodes MS channels. `StreamReader` is unchanged.

## 8. Importers

`ImportedDataset` gains `genomicStreams` and `spectralStreams`
(`Map<String, GenomicStreamSource>` / `SpectralStreamSource`, records
holding a `Supplier<Iterator<WrittenGenomicRun>>` /
`Supplier<Iterator<WrittenSpectralBatch>>` plus per-source options:
reference FASTA, embed flag, block policy, legacy flag, batch size,
chromatograms supplier). `ImportedDataset.write` creates the file with
the in-memory content as today, then reopens the root through the
provider in read-write mode and calls each source's `writeInto(study)`.
The importer classes gain streaming entry points and keep the whole-run
ones:

| importer | streaming API |
|---|---|
| `BamReader` | `Iterator<WrittenGenomicRun> iterBatches(name, region, batchReads)` over the htsjdk `SAMRecordIterator` (a `BatchAccumulator` builds parallel arrays per batch); `stream(name, region, referenceFasta, ...)` returns the source. Provenance as today. |
| `FastqReader` | `iterBatches(sampleName, batchReads)`; phred detection from the first batch as today. |
| `MzMLReader` | the SAX handler emits `WrittenSpectralBatch` every `batchSpectra` spectra through a callback; `stream(path)` returns a `SpectralStreamSource` whose iterator runs the parser on a bounded queue in a producer thread (SAX is push-only); chromatograms are collected during the parse and returned by `chromatogramsAfter`. |
| `ImporterRegistry.encode` | routes `bam/sam/cram`, `fastq`, `mzml` through the streams; other formats unchanged. |

`EncodeCli` keeps `--extra k=v` and understands `block_reads`,
`block_bytes`, `legacy_whole_channel`, `reference` (FASTA path),
`embed_reference`. `SpectralDataset.create` (all overloads) and
`ImportedDataset.write` accept the legacy flag per run.

## 9. Exporters

`BamWriter` and `FastqWriter` iterate `run.iterReads(0, n)` and write
records as they go (htsjdk `SAMFileWriter` is already streaming;
FASTQ through a buffered writer); `sequencesFull`/`qualitiesFull`/
`readNamesAll` are no longer called by exporters. `MzMLWriter` writes
to an output stream instead of a `StringBuilder`, tracks byte offsets
for the indexedmzML index and checksum as it goes, and iterates
`run.iterSpectra()`; the `spectrumList count` is known from
`spectrumCount()` up front. `ExportCli`, `RunSelection` and tio-browser's
`ExportTask` need no API change.

## 10. tio-browser

`ImportTask` routes BAM/SAM/CRAM and FASTQ through the stream sources
(FASTA stays whole-file; it is not a genomic run). Progress: the
sources report per batch through the existing `ProgressSink`.
`GenomicRowAdapter` (`objectAtIndex`) and `GenomicHeadersTable` work
unchanged over the block dispatch; the last-block cache makes scrolling
one decode per block. `ChromDistributionView` triggers the lazy index
load, as today's cost.

## 11. Testing

Java tests under `java/src/test/java/global/thalion/ttio/`:

- `ProviderTest`: extendable/`UINT64` cases (section 3), all four
  providers.
- `genomics/GenomicBlocksTest`: `sliceRun`/`concatRuns` round trip;
  `encodeBlock` on the m87 fixture equals the v1.8 writer's bytes for
  the same reads (per channel, per codec column).
- `genomics/GenomicStreamWriterTest`: m87 with `blockReads` 1, 25 and
  10^6; `readAt(i)`, `iterReads`, `readsInRegion` agree with a
  whole-run write; chromosome-change flush; zero-length-read block
  uses RANS_ORDER0 qualities; partial file (no `close`) readable up
  to the last block; legacy flag writes v1.8; `SpectralDataset.create`
  default is `blocks_v1`.
- `genomics/BlocksV1GoldenTest`: opens
  `python/tests/fixtures/genomic/blocks_v1_golden.tio`, checks
  `layout()`, `blockCount() == 4`, and the SAM 11-column digest of
  every read against the m87 source (same comparator as the Python
  `test_blocks_v1_golden.py`).
- `SpectralStreamWriterTest`: mzML fixture through the stream writer
  vs `AcquisitionRun.writeTo`: index and channel arrays equal;
  `channelRange`/`iterSpectra` equal `channels()`; FDZ1 header
  rewritten (`n_values`, `n_blocks`).
- `ImportExportTest` additions: streamed BAM/FASTQ/mzML import →
  export → digest equals the input; exporters run against a
  multi-block file.
- Signature round trip on a `blocks_v1` run.
- Cross-language: `Tests/`/`conformance/` Python matrix must stay
  green with the legacy pins in place; a Java-written `blocks_v1`
  file must open in Python (`test_blocks_v1_golden.py`-style check
  added under `python/tests/conformance/` reading a Java-produced
  fixture, generated by a Java tool at test time when `mvn` is
  available, skipped otherwise).

Memory ceiling: a synthetic 5 M-read FASTQ streamed with default policy
peaks under 2 GB heap (`-Xmx2g` on the test JVM; the test is tagged
slow and runs in CI's Java job as the Python one does).

## 12. Compatibility

- Java writes `blocks_v1` by default from this release; the CHANGELOG
  states it as it did for Python. `optLegacyWholeChannel` per run.
- Java reads both layouts forever. Files with an unknown `@layout`
  fail with a clear error.
- The `WrittenGenomicRun` record gains one component
  (`optLegacyWholeChannel`) with a delegating constructor; every
  existing constructor keeps working. `StorageGroup`/`StorageDataset`
  additions are default methods or overloads; third-party providers
  (`ProviderRegistry` loads by name) keep compiling and throw
  `UnsupportedOperationException` from `append` until they implement it.
- `AcquisitionRun.channels()` keeps its meaning; only the moment of
  decode moves.
- The Python cross-language fixtures stay pinned to legacy until ObjC
  reads blocks (sub-project 4 un-pins).

## 13. Risks and their handling

- `writeGenomicRunSubtree` over a `MemoryProvider` group: the plan's
  first task after the providers is a test that writes the m87 run
  into a memory root and reads it back with `GenomicRun.readFrom`;
  any HDF5-only branch found there is fixed before the encoder is
  built on it.
- `Hdf5CompoundIO` extendable compound with VL columns: the block
  index has none, but the API is general; the plan tests a VL-string
  extendable compound too, or documents the primitive-only limit if
  the split-write path resists it.
- htsjdk `IndexedFastaSequenceFile` returns upper/lower case as in the
  file, like Python's `LazyReference`; the MD5 must match Python's
  (`@md5` on the embedded reference). The golden fixture embeds a
  synthetic reference and pins this.
- The mzML producer thread: bounded queue, parser exceptions
  propagated to the consumer, thread daemon and joined on close.

## 14. Order of work (for the plan)

1. Providers (section 3) with tests.
2. Memory-provider round trip of the v1.8 writer; `GenomicWriteContext`.
3. `GenomicBlocks` encoder + tests.
4. `GenomicStreamWriter` + `LazyReference` + `SpectralDataset.create`
   default flip + tests.
5. `GenomicRun` blocks reader (`BlockTable`, `BlockView`, lazy index,
   `iterReads`) + golden fixture test + signatures + transport bulk
   fallback + suite fallout.
6. `FloatDeltaZstd` block API, `SpectralStreamWriter`, `AcquisitionRun`
   lazy channels + tests.
7. Streaming importers (BAM, FASTQ, mzML) + `ImportedDataset` streams
   + `EncodeCli` extras.
8. Streaming exporters (BAM/SAM, FASTQ, mzML).
9. tio-browser `ImportTask`.
10. Docs (`java/README.md`, `ARCHITECTURE.md`, CHANGELOG), full Java
    suite, Python conformance, PR.
