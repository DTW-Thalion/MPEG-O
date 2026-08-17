# Streaming import/export and `blocks_v1` in Objective-C — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The ObjC SDK reads and writes the `blocks_v1` genomic layout (format-spec §10.12), writes it by default, and streams BAM/FASTQ/mzML import and SAM/BAM/FASTQ/mzML export with bounded memory, matching Python (#290) and Java (#291).

**Architecture:** As in Java: providers gain extendable datasets; the storage-protocol genomic writer (brought to FQZCOMP parity) encodes each block into a `TTIOMemoryProvider` root and the block encoder harvests the bytes; `TTIOGenomicStreamWriter` appends blobs and index rows; the reader materialises one block as a v1.8-shaped memory group and opens `TTIOGenomicRun` over it with the parent's reference resolver. MS side: `TTIOSpectralStreamWriter` and range reads on `TTIOAcquisitionRun`.

**Tech Stack:** Objective-C (libobjc2, gnustep-base), HDF5 C API, samtools via `NSTask`, `NSXMLParser`. Build/test from `objc/`: `./build.sh` (build), `./build.sh check` (runs `Tests/obj/TTIOTests`); a single test group runs by editing nothing — the runner runs everything, ~2 min. Tools in `objc/Tools` (`TtioWriteGenomicFixture`, `TtioEncode`, `TtioExport`).

**Spec:** `docs/superpowers/specs/2026-08-17-streaming-blocks-v1-objc-design.md`; Java reference `java/src/main/java/global/thalion/ttio/{genomics/GenomicBlocks,genomics/GenomicStreamWriter,genomics/BlockTable,genomics/BlockView,SpectralStreamWriter,WrittenSpectralBatch,codecs/FloatDeltaZstd}.java` and the importer/exporter classes touched by #291.

## Global Constraints

- Block blobs byte-identical to a v1.8 write of the block's reads (the whole cross-language contract); index column order and forced codecs exactly as §10.12; blocks never span chromosomes; `sequences/data` group form; unknown `@layout` is an error.
- Public API source-compatible: new methods and optional protocol methods with adapter defaults; one new `TTIOWrittenGenomicRun` property (`optLegacyWholeChannel`).
- No AI attribution or change-describing comments anywhere; commit messages plain.
- Cross-language fixtures stay pinned to legacy until sub-project 4.
- Run `./build.sh check` before every commit; Python conformance (`python/tests/conformance`, `tests/validation/test_m89_cross_language.py`, `test_m82_3x3_matrix.py`) at Tasks 5, 8, 11.

Repository `~/TTI-O` (WSL), branch `streaming-blocks-v1-objc` off `main`. Paths below relative to `objc/Source/` unless noted. Test files go in `objc/Tests/`, registered in `Tests/GNUmakefile` (`TTIOTests_OBJC_FILES`) and `Tests/TTIOTestRunner.m` (extern + call).

---

### Task 1: Extendable datasets and `UInt64` in the four providers

**Files:** `Providers/TTIOStorageProtocols.h`, `Providers/TTIOCompoundField.h/.m` (`TTIOCompoundFieldKindUInt64 = 5`), `Providers/TTIOCanonicalBytes.m` (UInt64 as 8-byte LE), `HDF5/TTIOHDF5Group.h/.m` (`createDatasetNamed:…extendable:` with `H5S_UNLIMITED` maxdims and a chunk even when `length == 0`; `openDatasetNamed:` reads maxdims), `HDF5/TTIOHDF5Dataset.h/.m` (`_length` mutable, `_extendable`, `-isExtendable`, `-appendData:error:` = `H5Dset_extent` + hyperslab write, `-writeSlice:atOffset:error:`), `Dataset/TTIOCompoundIO.m` (+`createExtendableCompoundInGroup:name:fields:chunkRows:error:`, +`appendRows:toGroup:name:fields:error:` primitive kinds only, `fieldByteSize`/`ttioMakeCompoundType` UInt64 → `H5T_NATIVE_UINT64`), `Providers/TTIOHDF5Provider.m` (adapters: extendable create, `appendData`, `writeSlice`, `isExtendable`; compound adapter creates immediately when extendable; member-type inference sign-aware), `Providers/TTIOMemoryProvider.m` (concatenate `NSData`/rows), `Providers/TTIOSqliteProvider.m` (`extendable` column + `ensureExtendableColumn`, read-modify-write), `Providers/TTIOZarrProvider.m` (`_ttio_extendable` attr, rewrite shape). Test: `Tests/TestProviderExtendable.m` — on hdf5/memory/sqlite/zarr: append 3 batches of uint8, `readSliceAtOffset:` across a boundary, `writeSlice`, reopen keeps `isExtendable` and length; extendable compound `{start:UInt64,n:UInt32,score:Float64}` append 1+2 rows, `readRows`, kind on reopen, canonical bytes 60 long; non-extendable append fails; extendable with chunk 0 fails.
- Steps: write the test, register it, `./build.sh check` fails; implement per file; check passes; commit `feat(providers): extendable datasets, writeSlice and the UInt64 compound kind`.

### Task 2: Storage-path FQZCOMP parity and `TTIOGenomicWriteContext`

**Files:** `Genomics/TTIOGenomicWriteContext.h/.m` (`chromNameToId` mutable dict, `referenceMD5`; `+none`), `Dataset/TTIOSpectralDataset+GenomicWrite.m` (`_TTIO_M94Z_WriteQualitiesFqzcompNx16ZStorage` mirroring the HDF5 one over `id<TTIOStorageGroup>`; `writeGenomicRunStorage:` applies `_TTIO_M94_DefaultQualitiesCodec` and an explicit FQZCOMP override through it; new `+writeGenomicRunStorage:toGroup:name:context:error:` threading the map into `_TTIO_V17_BuildChromTables` / mate writer and `TTIOGenomicIndex -writeToGroup:nameToId:` and the MD5 into `_TTIO_V18_WriteRefDiffV2SequencesStorage`), `Genomics/TTIOGenomicIndex.h/.m` (`-writeToGroup:nameToId:error:`; `+namesInIdOrder:`), header export of `writeGenomicRunStorage:` in `TTIOSpectralDataset+GenomicWrite.h` (check name). Test: `Tests/TestGenomicBlocks.m` part 1 — m87 run (`TTIOBamReader`, skip when samtools absent; else the m82 100-read fixture builder from `TestM82GenomicRun.m`) written to `memory://` through the storage path with an FQZCOMP-default candidate (attach a reference so the v1.5 path applies, or override qualities to FQZCOMP) reads back through `TTIOGenomicRun` read for read; a pre-seeded shared map keeps its ids.
- Commit `refactor(genomics): storage-path FQZCOMP qualities and a shared write context`.

### Task 3: Block encoder `Genomics/TTIOGenomicBlocks`

`+blockChannels`, `+sliceRun:from:to:`, `+concatRuns:`, `+encodeBlock:context:error:` → `TTIOBlockBlobs` (blobs/codecs/extraAttrs dictionaries keyed by channel, nReads, nBases). Forced overrides as Java. `TTIOWrittenGenomicRun` gains `optLegacyWholeChannel` and copy helpers (`-copyWithSignalCodecOverrides:`, `-copyWithProvenance:`, `-copyWithOptLegacyWholeChannel:`). Test: slice/concat inverse; `encodeBlock` bytes equal a storage-path write of the same reads with the same overrides; zero-length read → RANS_ORDER0 qualities.
- Commit `feat(genomics): block encoder over the storage-path writer`.

### Task 4: `TTIOGenomicStreamWriter`, `TTIOLazyReference`, default flip

Port `GenomicStreamWriter.java` (`Genomics/TTIOGenomicStreamWriter.h/.m`, options object as in the spec; `INDEX_FIELDS` 19 columns; channel chunk 256 KiB; `runsGroup` maintains `@_run_names`; close writes name tables and provenance via `TTIOCompoundIO writeProvenance:` + `provenance_json`). `Genomics/TTIOLazyReference.h/.m` (`NSDictionary` subclass: `.fai` parse or in-process scan; `objectForKey:` loads with LRU 2; `keyEnumerator`, `count`; `lengthOf:`). Default flip in `+writeMinimalToPath:…genomicRuns:` (HDF5 path) and `writeMinimalGenomicViaProviderURL:` (storage path): each run through the stream writer unless `optLegacyWholeChannel`; both study groups are `id<TTIOStorageGroup>` (wrap the HDF5 study with `TTIOHDF5GroupAdapter`). Test `Tests/TestGenomicStreamWriter.m`: layout + index (19 columns, block_policy attr), chromosome cuts, legacy flag, single-read append equals batch, `writeMinimalToPath` default is blocks_v1 / legacy flag is v1.8. Then `./build.sh check` fallout list (tests asserting v1.8 layout get `optLegacyWholeChannel = YES`; reader-dependent failures wait for Task 5).
- Commit `feat(genomics): TTIOGenomicStreamWriter writes blocks_v1 by default; TTIOLazyReference`.

### Task 5: Reading `blocks_v1`; golden fixture; signatures; transport; fallout

`Genomics/TTIOBlockTable.h/.m`, `Genomics/TTIOBlockView.h/.m` (memory group; `-discard`), `TTIOGenomicRun`: `+openFromGroup:name:referenceResolver:error:`, layout dispatch, lazy `_index` (`-index` loads; `-readCount` from the table), `-layout`, `-blockCount`, `-chromosomeNames`, `-iterReadsFrom:to:usingBlock:`, dispatch in `readAtIndex:`/`readNameAtIndex:`/`cigarAtIndex:`/mate accessors/whole-channel accessors/bulk blob accessors/`wireCompressionForChannel:`; `_codecContext` uses the shared resolver. `Protection/TTIOSignatureManager.m` (`sequences/*` children + `blocks/index`), `Transport/TTIOTransportWriter.m` (bulk carriage only when whole-channel or one block). Tests: `Tests/TestBlocksV1Golden.m` (path `../python/tests/fixtures/genomic/blocks_v1_golden.tio`, SAM-11 md5 vs `m87_test.sam` — the digest helper mirrors `python/tests/_digests.py`), `Tests/TestGenomicBlocksReader.m` (block policies 1/3/10^6 vs whole run; unknown layout error; partial file; signatures round trip; multi-block transport round trip). Full `./build.sh check` green; Python conformance + validation xlang tests green.
- Commit `feat(genomics): read the blocks_v1 layout in TTIOGenomicRun; block index in signatures`.

### Task 6: FDZ block API, `TTIOSpectralStreamWriter`, lazy `TTIOAcquisitionRun`

`Codecs/TTIOFloatDeltaZstd.h/.m` (`+headerBytesForValues:blocks:`, `+encodeBlock:`, `+blockBytes:`, `TTIOFDZBlockTable`, `+readBlockTableWithReader:error:`, `+decodeBlock:table:reader:error:`; `encode` rewritten on top, bytes unchanged). `Run/TTIOWrittenSpectralBatch.h/.m`, `Run/TTIOSpectralStreamWriter.h/.m` (port of Java; extendable index columns and channels; FDZ buffering; header `writeSlice` at close; chromatograms/provenance via the run's existing static writers made class methods). `TTIOAcquisitionRun`: channel handles kept open (already), `-channelRange:start:count:error:` (overlay → cached full → codec 17 block-wise with one-block cache → hyperslab), `-iterSpectraWithBatch:usingBlock:`, `-spectrumAtIndex:` reads through `channelRange`; the full-column cache stays for `-spectra`. Test `Tests/TestSpectralStreamWriter.m` (streamed == `writeToGroup:` on `Tests/Fixtures/1min.mzML`; header finalised; `channelRange` slices; `iterSpectra` == `spectrumAtIndex:`), `Tests/TestFloatDeltaZstdBlocks.m`.
- Commit `feat(spectral): TTIOSpectralStreamWriter, codec-17 block API and range reads on TTIOAcquisitionRun`.

### Task 7: Streaming importers

`Import/TTIOGenomicStreamSource.h/.m`, `Import/TTIOSpectralStreamSource.h/.m` (`-writeIntoStudy:progress:error:`), `TTIOBamReader` (`-iterBatchesWithName:region:sample:batchReads:error:` over the samtools `NSTask` pipe reading lines; `-streamWithName:…`), `TTIOFastqReader` (`+iterBatchesFromPath:sample:batchReads:error:`, `+streamFromPath:…`), `TTIOMzMLReader` (parser on a background thread with an `NSCondition`-guarded bounded queue; `+streamFromPath:runName:batchSpectra:`), `TTIOImportedDataset` (`genomicStreams`, `spectralStreams`; `writeToPath:` reopens read-write via `TTIOProviderRegistry` and writes them; `opt_genomic` feature flag), reader adapters (`TTIOReaderAdapters.m`) for bam/sam/cram/mzml + `TtioEncode` extras. Test `Tests/TestStreamingImporters.m` (skip BAM parts without samtools).
- Commit `feat(importers): stream BAM/SAM/CRAM, FASTQ and mzML through the stream writers`.

### Task 8: Streaming exporters

`TTIOBamWriter` `-writeRun:(TTIOGenomicRun*)provenance:sort:progress:error:` iterating reads into the samtools pipe; `TTIOFastqWriter` `+writeRun:` streaming; `TTIOMzMLWriter` counting `NSOutputStream`; `TTIOWriterAdapters.m` use the run overloads. Test `Tests/TestStreamingExporters.m` (BAM digest vs source SAM; FASTQ bytes equal the whole-run export; mzML bytes equal the eager export).
- Commit `feat(exporters): stream SAM/BAM, FASTQ and mzML export`.

### Task 9: Tools, docs, cross-language test

`Tools/TtioWriteGenomicFixture.m --blocks <bam> <block-reads>`; `python/tests/conformance/test_blocks_v1_objc_written.py` (ObjC binary via `_resolve_objc_writer` from `test_m82_3x3_matrix.py`); `objc/README`/`ARCHITECTURE.md` ObjC rows, CHANGELOG entry, spec status note.
- Commit `docs: ObjC streaming import/export and blocks_v1`.

### Task 10: Suites and PR

`./build.sh check` green; Python full suite; attribution/style gate on commits and the PR body (five paragraphs, under 200 words, `--body-file`); push via Windows git; PR; watch CI; live-body audit.

## Self-review

Spec coverage: §3 → Task 2; §4 → Task 1; §5 → Tasks 3–4; §6 → Task 5; §7 → Task 6; §8 → Tasks 7–8; §9 → Tasks 5–9; §10 order kept. Names consistent with the spec: `TTIOGenomicWriteContext`, `TTIOGenomicBlocks`, `TTIOBlockBlobs`, `TTIOGenomicStreamWriter(Options)`, `TTIOLazyReference`, `TTIOBlockTable`, `TTIOBlockView`, `TTIOSpectralStreamWriter`, `TTIOWrittenSpectralBatch`, `TTIOGenomicStreamSource`, `TTIOSpectralStreamSource`.
