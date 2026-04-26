#ifndef TTIO_GENOMIC_RUN_H
#define TTIO_GENOMIC_RUN_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOAlignedRead;
@class TTIOGenomicIndex;
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
@interface TTIOGenomicRun : NSObject

@property (readonly, copy) NSString *name;
@property (readonly) TTIOAcquisitionMode acquisitionMode;
@property (readonly, copy) NSString *modality;
@property (readonly, copy) NSString *referenceUri;
@property (readonly, copy) NSString *platform;
@property (readonly, copy) NSString *sampleName;
@property (readonly, strong) TTIOGenomicIndex *index;

- (NSUInteger)readCount;

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

/** Reads on `chromosome` whose mapping position is in [start, end). */
- (NSArray<TTIOAlignedRead *> *)readsInRegion:(NSString *)chromosome
                                          start:(int64_t)start
                                            end:(int64_t)end;

/** M86 Phase B: return the full integer signal-channel array for
 *  `name` ("positions", "flags", or "mapping_qualities"), lazily
 *  decoded.
 *
 *  For codec-compressed integer channels (`@compression` names a TTIO
 *  rANS id) the entire dataset is read once on first access, decoded
 *  through the rANS codec, re-interpreted as the channel's natural
 *  little-endian integer dtype (positions → int64, flags → uint32,
 *  mapping_qualities → uint8 — Binding Decision §115), and cached on
 *  this `TTIOGenomicRun` instance per Binding Decision §116. For
 *  uncompressed channels (no `@compression` attribute or value 0) the
 *  dataset is read directly and re-interpreted via the same channel-
 *  name dtype lookup.
 *
 *  The returned NSData carries the LE byte representation of the
 *  array — callers re-interpret via `(int64_t *)data.bytes` etc. (the
 *  GNUstep host is little-endian on x86/ARM, so the LE bytes match
 *  the host representation directly; on big-endian platforms the
 *  caller must byte-swap, mirroring the write-side LE serialisation
 *  contract per Gotcha §128).
 *
 *  Per Binding Decision §119, this helper is **callable but not
 *  consumed by `-readAtIndex:`** — the per-read access path continues
 *  to use `self.index.{positions,mappingQualities,flags}` for byte
 *  parity with M82 readers. Phase B is primarily a write-side file-
 *  size optimisation; this reader hook is wired for round-trip
 *  conformance and any future reader that prefers `signal_channels/`
 *  over `genomic_index/`. */
- (NSData *)intChannelArrayNamed:(NSString *)name
                            error:(NSError **)error;

/** Open an existing /study/genomic_runs/<name>/ group. The caller
 *  resolves the run group and passes it as `runGroup`. */
+ (instancetype)openFromGroup:(id<TTIOStorageGroup>)runGroup
                          name:(NSString *)name
                         error:(NSError **)error;

@end

#endif
