#ifndef TTIO_GENOMIC_RUN_H
#define TTIO_GENOMIC_RUN_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOIndexable.h"
#import "Protocols/TTIORun.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOAlignedRead;
@class TTIOGenomicIndex;
@class TTIOProvenanceRecord;
@protocol TTIOStorageGroup;

/**
 * Lazy view over one /study/genomic_runs/<name>/ group.
 *
 * Materialises TTIOAlignedRead objects on demand from the signal
 * channels. The TTIOGenomicIndex is loaded eagerly at open time for
 * cheap filtering and offset lookups; the heavy signal channels
 * (sequences, qualities, plus 3 compounds) stay lazy on disk.
 *
 * Genomic analogue of TTIOAcquisitionRun.
 *
 * Cross-language equivalents:
 *   Python: ttio.genomic_run.GenomicRun
 *   Java:   global.thalion.ttio.genomics.GenomicRun
 */
@interface TTIOGenomicRun : NSObject <TTIOIndexable, TTIORun>

@property (readonly, copy) NSString *name;
@property (readonly) TTIOAcquisitionMode acquisitionMode;
@property (readonly, copy) NSString *modality;
@property (readonly, copy) NSString *referenceUri;
@property (readonly, copy) NSString *platform;
@property (readonly, copy) NSString *sampleName;
@property (readonly, strong) TTIOGenomicIndex *index;

- (NSUInteger)readCount;

/** Phase 1 TTIORun + TTIOIndexable conformance. -count returns the
 *  same value as -readCount; -objectAtIndex: returns the
 *  TTIOAlignedRead at ``index`` (or nil on error / out-of-range,
 *  matching the lenient TTIOIndexable contract used by
 *  TTIOAcquisitionRun). */
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)index;

/** Phase 1: per-run provenance records in insertion order. Reads
 *  the ``<run>/provenance/steps`` compound dataset written by
 *  +[TTIOSpectralDataset writeGenomicRun:toGroup:name:error:] when
 *  the WrittenGenomicRun carried any. Returns ``@[]`` for runs
 *  without provenance — closes the M91 read-side cross-modality
 *  query gap. */
- (NSArray<TTIOProvenanceRecord *> *)provenanceChain;

/** Materialise the read at `index`. Returns nil and sets *error on
 *  invalid index or I/O failure. */
- (TTIOAlignedRead *)readAtIndex:(NSUInteger)index
                            error:(NSError **)error;

/** Return the read name at `index`. Dispatches on the on-disk
 *  read_names dataset shape (M86 Phase E):
 *    - Compound `{value: VL_STRING}`: existing M82 read path.
 *    - Flat 1-D uint8 with `@compression == 8`: NAME_TOKENIZED
 *      decode-once-and-cache. The decoded list is materialised on
 *      first call and held for the lifetime of this run instance
 *      per Binding Decision §114. */
- (NSString *)readNameAtIndex:(NSUInteger)index
                         error:(NSError **)error;

/** Return the CIGAR string at `index`. Dispatches on the on-disk
 *  cigars dataset shape (M86 Phase C):
 *    - Compound `{value: VL_STRING}`: existing M82 read path.
 *    - Flat 1-D uint8 with `@compression`:
 *        * `4` (RANS_ORDER0) or `5` (RANS_ORDER1): TTIORansDecode
 *          then walk varint(len)+bytes per CIGAR.
 *        * `8` (NAME_TOKENIZED): TTIONameTokenizerDecode directly.
 *      Decoded list is materialised on first call and held for the
 *      lifetime of this run instance per Binding Decision §123 — a
 *      separate cache from `_decodedReadNames` since the two
 *      channels have independent dispatch shapes. */
- (NSString *)cigarAtIndex:(NSUInteger)index
                     error:(NSError **)error;

/** Reads on `chromosome` whose mapping position is in [start, end). */
- (NSArray<TTIOAlignedRead *> *)readsInRegion:(NSString *)chromosome
                                          start:(int64_t)start
                                            end:(int64_t)end;

// v1.6 (L4): -intChannelArrayNamed:error: REMOVED. The helper supported
// reading positions/flags/mapping_qualities from signal_channels/ via
// codec dispatch — but those datasets no longer exist in v1.6 files
// (they live exclusively in genomic_index/, accessed via
// self.index.{positions,mappingQualities,flags}). See
// docs/format-spec.md §10.7.

/** Open an existing /study/genomic_runs/<name>/ group. The caller
 *  resolves the run group and passes it as `runGroup`. */
+ (instancetype)openFromGroup:(id<TTIOStorageGroup>)runGroup
                          name:(NSString *)name
                         error:(NSError **)error;

/** M90.10: return the M86 codec id (TTIOCompression value) declared
 *  on the named signal channel via its `@compression` attribute, or
 *  0 (NONE) if the attribute is absent. The transport writer probes
 *  this for sequences/qualities to decide whether each per-AU slice
 *  should be re-encoded with that codec on the wire. */
- (uint8_t)wireCompressionForChannel:(NSString *)name;

@end

#endif
