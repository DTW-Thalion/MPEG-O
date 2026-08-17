# Streaming import/export and `blocks_v1` in Objective-C (sub-project 3)

> **Status (2026-08-17).** Design for the Objective-C implementation of
> `docs/format-spec.md` section 10.12 and of streaming import/export.
> Sub-project 3 of 4; sub-project 1 (format + Python) merged as PR #290,
> sub-project 2 (Java) is PR #291. The format contract is section
> 10.12; the Java design
> (`docs/superpowers/specs/2026-08-17-streaming-blocks-v1-java-design.md`)
> and its code are the closest reference, the Python code the
> normative one. The decode contract is
> `python/tests/fixtures/genomic/blocks_v1_golden.tio`.

> **Out of scope:** un-pinning the cross-language fixtures and the
> `GENOMIC_RUNS_BLOCKS` matrix cell (sub-project 4, follows this one);
> codec wire changes; per-AU/region encryption of genomic channels
> (whole-channel layout only, unchanged); the vendor importers that
> shell out to converters.

## 0. Why

The ObjC SDK has the same shape as Java had before #291: every
genomic channel is one blob per run, `TTIOAcquisitionRun` decodes a
whole channel on first access, `TTIOBamReader` builds a whole
`TTIOWrittenGenomicRun`, and a `blocks_v1` file does not open. Once
ObjC reads and writes the layout the three implementations are
interchangeable again and sub-project 4 can un-pin the cross-language
fixtures.

## 1. Goals

1. `TTIOGenomicRun` reads `blocks_v1` (the golden fixture, Python- and
   Java-written files) one block at a time and still reads v1.8.
2. `TTIOGenomicStreamWriter` writes `blocks_v1` with bounded memory;
   `+writeMinimalToPath:…genomicRuns:` and the provider write path emit
   it by default; `optLegacyWholeChannel` on `TTIOWrittenGenomicRun`
   restores v1.8.
3. `TTIOSpectralStreamWriter` and range reads on `TTIOAcquisitionRun`
   (`channelRange`, `iterSpectra`).
4. All four ObjC providers: extendable datasets, `writeSlice`,
   `TTIOCompoundFieldKindUInt64`.
5. BAM/SAM/CRAM (samtools pipe), FASTQ and mzML importers stream;
   SAM/BAM, FASTQ and mzML exporters stream; `TtioEncode`/`TtioExport`
   use them.
6. ObjC suite green; Python conformance green (fixtures still pinned).

Non-goals: changing `TTIOAcquisitionRun`'s eager `-spectra`; a finer
region index; multi-threaded encode.

## 2. Format contract

Format-spec 10.12, unchanged; see the Java spec section 2 for the
one-paragraph summary. ObjC adds nothing.

## 3. Two writer paths in ObjC, and which one the block encoder uses

`TTIOSpectralDataset+GenomicWrite.m` has an HDF5-direct writer
(`+writeGenomicRun:toGroup:name:error:` on `TTIOHDF5Group`, "for byte
parity") and a storage-protocol writer
(`+writeGenomicRunStorage:toGroup:name:error:` on
`id<TTIOStorageGroup>`, used for memory/sqlite/zarr). The storage path
lacks the FQZCOMP_NX16_Z qualities writer
(`_TTIO_M94Z_WriteQualitiesFqzcompNx16Z` takes a `TTIOHDF5Group`) and
the qualities auto-default (`_TTIO_M94_DefaultQualitiesCodec`) is
applied on the HDF5 path only; a qualities override of FQZCOMP on the
storage path goes through `_TTIO_M86_EncodeWithCodec` with an empty
codec context and cannot succeed.

The block encoder runs the writer over a `TTIOMemoryProvider` group
(as Java and Python do), so the storage path is brought to parity
first: a `_TTIO_M94Z_WriteQualitiesFqzcompNx16ZStorage` variant, called
from `writeGenomicRunStorage:` both when the run's default resolves to
FQZCOMP (`_TTIO_M94_DefaultQualitiesCodec`) and when the caller
overrides `qualities` with FQZCOMP. This also makes a v1.8 run written
to memory/sqlite/zarr carry the same qualities codec as one written to
HDF5, which the Python and Java writers already do. The
storage-path writer then encodes every block; the HDF5-direct writer
stays as it is for the legacy layout on HDF5 (`optLegacyWholeChannel`)
and for byte parity of the existing fixtures.

Shared writer state (chromosome-id map, reference MD5) travels as an
extra argument on the storage-path writer and its helpers
(`_TTIO_V17_BuildChromTables`, `TTIOGenomicIndex -writeToGroup:`,
`_TTIO_M93_ReferenceMD5ForRun`), the ObjC twin of Java's
`GenomicWriteContext`: `TTIOGenomicWriteContext` with
`chromNameToId` (`NSMutableDictionary<NSString*,NSNumber*>`, grown in
place) and `referenceMD5` (`NSData`, nil = compute).

## 4. Providers

`TTIOStorageProtocols.h`:

```objc
// TTIOStorageGroup, new optional-with-default methods
- (id<TTIOStorageDataset>)createDatasetNamed:(NSString *)name precision:(TTIOPrecision)p
        length:(NSUInteger)length chunkSize:(NSUInteger)chunk compression:(TTIOCompression)c
        compressionLevel:(NSUInteger)level extendable:(BOOL)extendable error:(NSError **)error;
- (id<TTIOStorageDataset>)createCompoundDatasetNamed:(NSString *)name fields:(NSArray<TTIOCompoundField*>*)f
        count:(NSUInteger)count extendable:(BOOL)extendable chunkRows:(NSUInteger)rows error:(NSError **)error;
// TTIOStorageDataset
- (BOOL)isExtendable;
- (BOOL)appendData:(id)data error:(NSError **)error;      // NSData of packed LE elements, or NSArray of row dicts
- (BOOL)writeSlice:(id)data atOffset:(NSUInteger)offset error:(NSError **)error;
```

`extendable` requires `chunk > 0`; `append` on a non-extendable dataset
returns NO with an error. Provider mechanics as in Java: HDF5
`H5S_UNLIMITED` maxdims + `H5Dset_extent` + hyperslab write in
`TTIOHDF5Dataset` (`-appendData:`, `-writeSlice:atOffset:`,
`-isExtendable`), extendable compound on HDF5 primitive-kind only
(packed struct hyperslab write in `TTIOCompoundIO`), memory
concatenation, SQLite read-modify-write with an `extendable` column
(same DDL as Python), Zarr rewrite with `_ttio_extendable`.
`TTIOCompoundFieldKindUInt64 = 5`; canonical bytes as 8-byte LE;
`TTIOHDF5Provider` maps an unsigned 8-byte member to it on read.

## 5. Genomic block encoder and stream writer

`Genomics/TTIOGenomicBlocks.{h,m}` (class methods):
`+blockChannels`, `+sliceRun:from:to:`, `+concatRuns:`,
`+encodeBlock:context:error:` → `TTIOBlockBlobs` (blobs, codecs,
extraAttrs, nReads, nBases), applying the forced codecs of 10.12.3 and
harvesting from a `TTIOMemoryProvider` root written by
`writeGenomicRunStorage:`.

`Genomics/TTIOGenomicStreamWriter.{h,m}`:

```objc
@interface TTIOGenomicStreamWriterOptions : NSObject <NSCopying>
@property TTIOAcquisitionMode acquisitionMode; @property NSString *referenceUri, *platform, *sampleName;
@property NSDictionary<NSString*,NSData*> *referenceChromSeqs; @property BOOL embedReference;
@property NSUInteger blockReads; @property unsigned long long blockBytes;   // defaults 1 000 000 / 256 MiB
@property BOOL optDisableQualitiesV5; @property NSDictionary<NSString*,NSNumber*> *signalCodecOverrides;
@property TTIOCompression signalCompression; @property BOOL optLegacyWholeChannel;
@property NSArray<TTIOProvenanceRecord*> *provenanceRecords;
+ (instancetype)optionsFromRun:(TTIOWrittenGenomicRun *)run;
@end
@interface TTIOGenomicStreamWriter : NSObject
- (instancetype)initWithStudyGroup:(id<TTIOStorageGroup>)study runName:(NSString *)name options:(TTIOGenomicStreamWriterOptions *)o;
- (BOOL)appendRead:(TTIOAlignedRead *)read error:(NSError **)error;
- (BOOL)appendBatch:(TTIOWrittenGenomicRun *)batch error:(NSError **)error;
- (BOOL)flush:(NSError **)error;
- (BOOL)close:(NSError **)error;
@property (readonly) unsigned long long readCount; @property (readonly) NSUInteger blockCount;
@end
```

Behaviour line for line with `stream_writer.py` / Java. The
`referenceChromSeqs` dictionary may be a `TTIOLazyReference`
(`NSDictionary` subclass over an indexed FASTA, samtools-free: reads
`.fai`, loads a chromosome on `objectForKey:`, LRU of two; creates the
`.fai` itself by scanning the FASTA when absent, as Python does with
`samtools faidx` when available — ObjC scans in-process so it needs no
samtools).

`+writeMinimalToPath:…genomicRuns:` and `writeMinimalGenomicViaProviderURL:`
route each `TTIOWrittenGenomicRun` through the stream writer unless
`run.optLegacyWholeChannel` (new property, default NO).

## 6. Reading `blocks_v1`

`TTIOGenomicRun +openFromGroup:name:error:` reads `@layout`:
`blocks_v1` → `TTIOBlockTable` (from `blocks/index` rows) and a lazy
`TTIOGenomicIndex` (loaded on first `-index`; `-readCount` from the
table); `whole`/absent → today; other → error `TTIOErrorUnsupportedLayout`.
`TTIOBlockView` materialises a block as a v1.8-shaped
`TTIOMemoryProvider` group (Java's `BlockView`); the view is opened
with `+openFromGroup:name:referenceResolver:error:` so it shares the
parent's `TTIOReferenceResolver` (built once from the HDF5 root as
`_codecContext` does today; the memory group has no `unwrap`). One
view cached. Dispatch in `readAtIndex:`, `readNameAtIndex:`,
`cigarAtIndex:`, mate accessors, `wholeSequencesData` /
`wholeQualitiesData` / `allReadNames` (concatenate over blocks),
`readRefDiffV2BlobBytes` etc. (one-block runs only, else nil),
`wireCompressionForChannel:` (block-0 codec when 4/5/6, else 0), new
`-iterReadsFrom:to:usingBlock:` and `-layout` / `-blockCount` /
`-chromosomeNames`. `TTIOSignatureManager` covers `sequences/data`
and `blocks/index`; the transport writer sends multi-block runs per AU
(bulk carriage only for whole-channel or one-block runs).

## 7. Spectral

`TTIOFloatDeltaZstd`: `+headerBytesForValues:blocks:`,
`+encodeBlock:`, `+blockBytes:`, `+readBlockTable:` (over a byte-range
block), `+decodeBlock:table:reader:`. `TTIOSpectralStreamWriter`
(`Run/TTIOSpectralStreamWriter.{h,m}`) with `TTIOWrittenSpectralBatch`
(offsets, lengths, index columns, optional M74/centroided,
channelData) — same layout as `-writeToGroup:` writes.
`TTIOAcquisitionRun` gains `-channelRange:start:count:error:` (codec 17
decodes only the blocks the range covers, one-block cache; codec 0
hyperslab) and `-iterSpectraWithBatch:usingBlock:`; `-spectrumAtIndex:`
reads through `channelRange` instead of the full-column cache, and
`-spectra` keeps its meaning.

## 8. Importers and exporters

`TTIOBamReader`: `-iterBatches:…` over the samtools text pipe
(`NSTask`, line by line, batches of 100 000 reads) and
`-streamWithName:region:sample:referenceFasta:embed:` returning
`TTIOGenomicStreamSource`; `TTIOFastqReader` likewise;
`TTIOMzMLReader`: `NSXMLParser` on a producer thread feeding a bounded
queue of `TTIOWrittenSpectralBatch` (`NSCondition`), `+streamFromPath:`
→ `TTIOSpectralStreamSource`; `TTIOImportedDataset` gains
`genomicStreams`/`spectralStreams` written after the static content
through a read-write reopen; `TtioEncode` reads the same extras as
Java (`block_reads`, `block_bytes`, `legacy_whole_channel`,
`reference`, `embed_reference`). Exporters: `TTIOBamWriter`
`-writeRun:(TTIOGenomicRun*)…` iterating reads (samtools view -b pipe
as today), `TTIOFastqWriter` `+writeRun:` iterating reads,
`TTIOMzMLWriter` writing to an `NSOutputStream` with a byte counter.

## 9. Testing

`Tests/TestBlocksV1Golden.m` (opens the Python golden fixture, checks
layout, 4 blocks, 10 reads, SAM-11 digest against `m87_test.sam`),
`Tests/TestGenomicStreamWriter.m` (blocks/index layout, chromosome
cuts, legacy flag, block policies 1/3/10^6 agree with the whole
decode, partial file), `Tests/TestSpectralStreamWriter.m` (streamed
== eager, header finalised, `channelRange`), `Tests/TestStreamingImporters.m`
and `TestStreamingExporters.m`, provider extendable round trips in the
existing provider tests, `python/tests/conformance/test_blocks_v1_objc_written.py`
(the `TtioWriteGenomicFixture` tool gains `--blocks`), and the
existing ObjC-writes/Java-reads matrix stays pinned to legacy.

## 10. Order of work

Providers → storage-path FQZCOMP parity + write context → block
encoder → stream writer + default flip → reader + golden + signatures
+ transport → FDZ block API + spectral writer + lazy reads →
importers → exporters → tools/docs → suites → PR. Sub-project 4 then
un-pins the fixtures and adds the `GENOMIC_RUNS_BLOCKS` cell.
