/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "Genomics/TTIOGenomicStreamWriter.h"
#import "Core/TTIOThreads.h"
#import "Genomics/TTIOGenomicBlocks.h"
#import "Genomics/TTIOGenomicWriteContext.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Dataset/TTIOSpectralDataset+GenomicWrite.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Providers/TTIOCompoundField.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "HDF5/TTIOHDF5Group.h"
#import "Dataset/TTIOCompoundIO.h"
#import <pthread.h>

static NSString *const kLayout = @"blocks_v1";
static const NSUInteger kDefaultBlockReads = 1000000;
static const unsigned long long kDefaultBlockBytes = 256ULL << 20;
static const NSUInteger kChannelChunk = 256 << 10;
static const NSUInteger kIndexChunkRows = 1024;
static const NSUInteger kIndexArrayChunk = 65536;

@implementation TTIOGenomicStreamWriterOptions

- (instancetype)init
{
    self = [super init];
    if (self) {
        _acquisitionMode = 0;
        _blockReads = kDefaultBlockReads;
        _blockBytes = kDefaultBlockBytes;
        _signalCodecOverrides = @{};
        _signalCompression = TTIOCompressionZlib;
        _provenanceRecords = @[];
    }
    return self;
}

+ (instancetype)defaultOptions
{
    return [[self alloc] init];
}

+ (instancetype)optionsFromRun:(TTIOWrittenGenomicRun *)run
{
    TTIOGenomicStreamWriterOptions *o = [[self alloc] init];
    o.acquisitionMode = run.acquisitionMode;
    o.referenceUri = run.referenceUri;
    o.platform = run.platform;
    o.sampleName = run.sampleName;
    o.referenceChromSeqs = run.referenceChromSeqs;
    o.embedReference = run.embedReference;
    o.optDisableQualitiesV5 = run.optDisableQualitiesV5;
    o.signalCodecOverrides = run.signalCodecOverrides ?: @{};
    o.signalCompression = run.signalCompression;
    o.optLegacyWholeChannel = run.optLegacyWholeChannel;
    o.provenanceRecords = run.provenanceRecords ?: @[];
    return o;
}

- (id)copyWithZone:(NSZone *)zone
{
    TTIOGenomicStreamWriterOptions *o = [[[self class] allocWithZone:zone] init];
    o.acquisitionMode = _acquisitionMode;
    o.referenceUri = _referenceUri;
    o.platform = _platform;
    o.sampleName = _sampleName;
    o.referenceChromSeqs = _referenceChromSeqs;
    o.embedReference = _embedReference;
    o.blockReads = _blockReads;
    o.blockBytes = _blockBytes;
    o.optDisableQualitiesV5 = _optDisableQualitiesV5;
    o.signalCodecOverrides = _signalCodecOverrides;
    o.signalCompression = _signalCompression;
    o.optLegacyWholeChannel = _optLegacyWholeChannel;
    o.provenanceRecords = _provenanceRecords;
    o.threads = _threads;
    return o;
}

@end

/** One block in flight: filled by the encode operation, written in
 *  sequence order by the caller's thread. */
@interface TTIOInFlightBlock : NSObject
@property (nonatomic, strong) TTIOWrittenGenomicRun *block;
@property (nonatomic, strong, nullable) TTIOBlockBlobs *blobs;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic) BOOL done;
@end

@implementation TTIOInFlightBlock
@end

@implementation TTIOGenomicStreamWriter {
    id<TTIOStorageGroup> _study;
    NSString *_name;
    TTIOGenomicStreamWriterOptions *_opt;
    NSMutableArray<TTIOWrittenGenomicRun *> *_pending;
    NSUInteger _pendingReads;
    unsigned long long _pendingBytes;
    NSString *_pendingChrom;
    NSMutableDictionary<NSString *, NSNumber *> *_chromMap;
    NSData *_referenceMD5;
    unsigned long long _readCount;
    unsigned long long _baseCount;
    NSUInteger _blockCount;
    id<TTIOStorageGroup> _rg;
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *_channelDs;
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *_idxDs;
    id<TTIOStorageDataset> _indexDs;
    BOOL _embedded;
    BOOL _closed;
    NSMutableArray<TTIOWrittenGenomicRun *> *_legacyParts;
    NSUInteger _threads;
    TTIOThreadPool *_pool;
    NSMutableArray<TTIOInFlightBlock *> *_inflight;
    NSCondition *_cond;
}

+ (NSString *)layout { return kLayout; }
+ (NSUInteger)channelChunk { return kChannelChunk; }

static NSArray *gIndexFields = nil;
static pthread_once_t gIndexFieldsOnce = PTHREAD_ONCE_INIT;

static void ttioBuildIndexFields(void)
{
    @autoreleasepool {
        NSMutableArray *f = [NSMutableArray array];
        [f addObject:[TTIOCompoundField fieldWithName:@"read_start" kind:TTIOCompoundFieldKindUInt64]];
        [f addObject:[TTIOCompoundField fieldWithName:@"n_reads" kind:TTIOCompoundFieldKindUInt32]];
        [f addObject:[TTIOCompoundField fieldWithName:@"base_start" kind:TTIOCompoundFieldKindUInt64]];
        [f addObject:[TTIOCompoundField fieldWithName:@"n_bases" kind:TTIOCompoundFieldKindUInt64]];
        for (NSString *ch in [TTIOGenomicBlocks blockChannels]) {
            [f addObject:[TTIOCompoundField fieldWithName:[ch stringByAppendingString:@"_off"]
                                                     kind:TTIOCompoundFieldKindUInt64]];
            [f addObject:[TTIOCompoundField fieldWithName:[ch stringByAppendingString:@"_len"]
                                                     kind:TTIOCompoundFieldKindUInt64]];
        }
        for (NSString *ch in [TTIOGenomicBlocks blockChannels]) {
            [f addObject:[TTIOCompoundField fieldWithName:[ch stringByAppendingString:@"_codec"]
                                                     kind:TTIOCompoundFieldKindUInt32]];
        }
        gIndexFields = [f copy];
    }
}

+ (NSArray<TTIOCompoundField *> *)indexFields
{
    pthread_once(&gIndexFieldsOnce, ttioBuildIndexFields);
    return gIndexFields;
}

- (instancetype)initWithStudyGroup:(id<TTIOStorageGroup>)study
                           runName:(NSString *)runName
                           options:(TTIOGenomicStreamWriterOptions *)options
{
    self = [super init];
    if (self) {
        _study = study;
        _name = [runName copy];
        _opt = options ? [options copy] : [TTIOGenomicStreamWriterOptions defaultOptions];
        if (_opt.blockReads < 1) _opt.blockReads = 1;
        if (_opt.blockBytes < 1) _opt.blockBytes = 1;
        _pending = [NSMutableArray array];
        _chromMap = [NSMutableDictionary dictionary];
        _channelDs = [NSMutableDictionary dictionary];
        _idxDs = [NSMutableDictionary dictionary];
        _legacyParts = [NSMutableArray array];
        _threads = [TTIOThreads resolve:_opt.threads ? @(_opt.threads) : nil];
        _pool = [TTIOThreadPool poolWithThreads:_opt.optLegacyWholeChannel ? 1 : _threads];
        _inflight = [NSMutableArray array];
        _cond = [NSCondition new];
    }
    return self;
}

- (NSUInteger)threads { return _threads; }

+ (void)registerBlockChromosomes:(TTIOWrittenGenomicRun *)block
                         intoMap:(NSMutableDictionary<NSString *, NSNumber *> *)map
{
    for (NSString *n in block.chromosomes) {
        if (map[n] == nil) map[n] = @(map.count);
    }
    for (NSString *n in block.mateChromosomes) {
        if (n.length > 0 && ![n isEqualToString:@"*"] && ![n isEqualToString:@"="] && map[n] == nil) {
            map[n] = @(map.count);
        }
    }
}

- (unsigned long long)readCount { return _readCount; }
- (NSUInteger)blockCount { return _blockCount; }
- (TTIOGenomicStreamWriterOptions *)options { return [_opt copy]; }

// ── run construction helpers ─────────────────────────────────────

- (TTIOWrittenGenomicRun *)_runWithMeta:(TTIOWrittenGenomicRun *)run
{
    TTIOWrittenGenomicRun *r = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:_opt.acquisitionMode
                   referenceUri:_opt.referenceUri
                       platform:_opt.platform
                     sampleName:_opt.sampleName
                      positions:run.positionsData
               mappingQualities:run.mappingQualitiesData
                          flags:run.flagsData
                      sequences:run.sequencesData
                      qualities:run.qualitiesData
                        offsets:run.offsetsData
                        lengths:run.lengthsData
                         cigars:run.cigars
                      readNames:run.readNames
                mateChromosomes:run.mateChromosomes
                  matePositions:run.matePositionsData
                templateLengths:run.templateLengthsData
                    chromosomes:run.chromosomes
              signalCompression:_opt.signalCompression
           signalCodecOverrides:_opt.signalCodecOverrides];
    r.optDisableQualitiesV5 = _opt.optDisableQualitiesV5;
    r.embedReference = _opt.embedReference;
    r.referenceChromSeqs = _opt.referenceChromSeqs;
    r.provenanceRecords = @[];
    r.optLegacyWholeChannel = NO;
    return r;
}

- (TTIOWrittenGenomicRun *)_singleReadRun:(TTIOAlignedRead *)r
{
    NSData *seq = r.sequence ? [r.sequence dataUsingEncoding:NSASCIIStringEncoding] : nil;
    if (!seq) seq = [NSData data];
    NSData *qual = r.qualities ?: [NSData data];
    NSString *mate = (r.mateChromosome == nil || r.mateChromosome.length == 0) ? @"*" : r.mateChromosome;
    int64_t pos = r.position;
    uint8_t mapq = r.mappingQuality;
    uint32_t flags = r.flags;
    uint64_t off = 0;
    uint32_t len = (uint32_t)seq.length;
    int64_t mpos = r.matePosition;
    int32_t tlen = r.templateLength;
    TTIOWrittenGenomicRun *run = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:_opt.acquisitionMode
                   referenceUri:_opt.referenceUri
                       platform:_opt.platform
                     sampleName:_opt.sampleName
                      positions:[NSData dataWithBytes:&pos length:sizeof(pos)]
               mappingQualities:[NSData dataWithBytes:&mapq length:1]
                          flags:[NSData dataWithBytes:&flags length:sizeof(flags)]
                      sequences:seq
                      qualities:qual
                        offsets:[NSData dataWithBytes:&off length:sizeof(off)]
                        lengths:[NSData dataWithBytes:&len length:sizeof(len)]
                         cigars:@[r.cigar ?: @"*"]
                      readNames:@[r.readName ?: @"*"]
                mateChromosomes:@[mate]
                  matePositions:[NSData dataWithBytes:&mpos length:sizeof(mpos)]
                templateLengths:[NSData dataWithBytes:&tlen length:sizeof(tlen)]
                    chromosomes:@[r.chromosome ?: @"*"]
              signalCompression:_opt.signalCompression
           signalCodecOverrides:_opt.signalCodecOverrides];
    run.optDisableQualitiesV5 = _opt.optDisableQualitiesV5;
    run.embedReference = _opt.embedReference;
    run.referenceChromSeqs = _opt.referenceChromSeqs;
    return run;
}

// ── appending ────────────────────────────────────────────────────

- (BOOL)appendRead:(TTIOAlignedRead *)read error:(NSError **)error
{
    return [self appendBatch:[self _singleReadRun:read] error:error];
}

- (BOOL)appendBatch:(TTIOWrittenGenomicRun *)batch error:(NSError **)error
{
    if (_closed) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"genomic stream writer is closed");
        return NO;
    }
    NSUInteger n = batch.readCount;
    if (n == 0) return YES;
    if (_opt.optLegacyWholeChannel) {
        [_legacyParts addObject:batch];
        return YES;
    }
    NSArray<NSString *> *chroms = batch.chromosomes;
    const uint32_t *lens = (const uint32_t *)batch.lengthsData.bytes;
    NSUInteger start = 0;
    while (start < n) {
        NSString *chrom = chroms[start];
        NSUInteger segEnd = start + 1;
        while (segEnd < n && [chroms[segEnd] isEqualToString:chrom]) segEnd++;
        if (_pending.count > 0 && ![chrom isEqualToString:_pendingChrom]) {
            if (![self flush:error]) return NO;
        }
        _pendingChrom = chrom;
        while (start < segEnd) {
            NSUInteger roomReads = _opt.blockReads > _pendingReads ? _opt.blockReads - _pendingReads : 0;
            unsigned long long roomBytes = _opt.blockBytes > _pendingBytes ? _opt.blockBytes - _pendingBytes : 0;
            NSUInteger stop = MIN(segEnd, start + MAX(roomReads, (NSUInteger)1));
            unsigned long long cum = 0;
            NSUInteger fit = 0;
            for (NSUInteger i = start; i < stop; i++) {
                cum += lens[i];
                if (cum <= roomBytes) fit++; else break;
            }
            if (fit < stop - start) stop = start + MAX(fit, (NSUInteger)1);
            TTIOWrittenGenomicRun *part = (start == 0 && stop == n)
                ? batch : [TTIOGenomicBlocks sliceRun:batch from:start to:stop];
            [_pending addObject:part];
            _pendingReads += stop - start;
            for (NSUInteger i = start; i < stop; i++) _pendingBytes += lens[i];
            if (_pendingReads >= _opt.blockReads || _pendingBytes >= _opt.blockBytes) {
                if (![self _cutBlock:error]) return NO;
            }
            start = stop;
        }
    }
    return YES;
}

- (BOOL)flush:(NSError **)error
{
    /* The public barrier: cut the pending block and write everything in
     * flight, so an unclosed file's flushed reads are on storage. */
    if (![self _cutBlock:error]) return NO;
    return [self _drainUntil:0 error:error];
}

- (BOOL)_cutBlock:(NSError **)error
{
    if (_opt.optLegacyWholeChannel || _pending.count == 0) return YES;
    TTIOWrittenGenomicRun *block = [TTIOGenomicBlocks concatRuns:_pending];
    [_pending removeAllObjects];
    _pendingReads = 0;
    _pendingBytes = 0;
    block = [self _runWithMeta:block];
    if (_referenceMD5 == nil && _opt.referenceChromSeqs != nil) {
        _referenceMD5 = [TTIOSpectralDataset referenceMD5ForRun:block];
    }
    if (!_embedded && _opt.embedReference) {
        if (![TTIOSpectralDataset embedReferencesForRuns:@[block] inStudy:_study error:error]) return NO;
        _embedded = YES;
    }
    [TTIOSpectralDataset validateGenomicCodecOverridesForRun:block];
    [[self class] registerBlockChromosomes:block intoMap:_chromMap];
    TTIOGenomicWriteContext *ctx =
        [TTIOGenomicWriteContext contextWithChromNameToId:_chromMap referenceMD5:_referenceMD5];
    if (_pool.queue == nil) {
        TTIOBlockBlobs *blobs = [TTIOGenomicBlocks encodeBlock:block context:ctx error:error];
        if (!blobs) return NO;
        return [self _writeEncoded:block blobs:blobs error:error];
    }
    if (![self _drainUntil:_threads error:error]) return NO;
    /* The worker reads the map while later flushes mutate it: give each
     * block a snapshot (registration above fixed every id it needs). */
    TTIOGenomicWriteContext *bctx =
        [TTIOGenomicWriteContext contextWithChromNameToId:[_chromMap mutableCopy]
                                             referenceMD5:_referenceMD5];
    TTIOInFlightBlock *f = [TTIOInFlightBlock new];
    f.block = block;
    [_inflight addObject:f];
    NSCondition *cond = _cond;
    [_pool.queue addOperationWithBlock:^{
        NSError *e = nil;
        TTIOBlockBlobs *b = nil;
        @try {
            b = [TTIOGenomicBlocks encodeBlock:block context:bctx error:&e];
        } @catch (NSException *ex) {
            /* NSOperationQueue swallows exceptions; surface them as the
             * block's error so the drain completes (and the serial path's
             * raise becomes the caller's NSError). */
            b = nil;
            e = TTIOMakeError(TTIOErrorDatasetWrite, @"%@: %@", ex.name, ex.reason);
        }
        [cond lock];
        f.blobs = b;
        f.error = e;
        f.done = YES;
        [cond broadcast];
        [cond unlock];
    }];
    return YES;
}

/** Write completed blocks in sequence order; wait on the oldest until at
 *  most blockUntil remain in flight. */
- (BOOL)_drainUntil:(NSUInteger)blockUntil error:(NSError **)error
{
    while (_inflight.count > 0) {
        TTIOInFlightBlock *f = _inflight.firstObject;
        [_cond lock];
        if (_inflight.count <= blockUntil && !f.done) {
            [_cond unlock];
            break;
        }
        while (!f.done) [_cond wait];
        [_cond unlock];
        [_inflight removeObjectAtIndex:0];
        if (!f.blobs) {
            if (error) *error = f.error;
            return NO;
        }
        if (![self _writeEncoded:f.block blobs:f.blobs error:error]) return NO;
    }
    return YES;
}

- (BOOL)_writeEncoded:(TTIOWrittenGenomicRun *)block blobs:(TTIOBlockBlobs *)blobs error:(NSError **)error
{
    if (![self _ensureLayout:error]) return NO;

    NSArray<TTIOCompoundField *> *fields = [[self class] indexFields];
    NSMutableDictionary *row = [NSMutableDictionary dictionaryWithCapacity:fields.count];
    row[@"read_start"] = @(_readCount);
    row[@"n_reads"] = @((uint32_t)blobs.nReads);
    row[@"base_start"] = @(_baseCount);
    row[@"n_bases"] = @(blobs.nBases);
    for (NSString *ch in [TTIOGenomicBlocks blockChannels]) {
        NSData *data = blobs.blobs[ch] ?: [NSData data];
        NSNumber *codec = blobs.codecs[ch] ?: @0;
        row[[ch stringByAppendingString:@"_codec"]] = @((uint32_t)[codec unsignedIntegerValue]);
        id<TTIOStorageDataset> ds = _channelDs[ch];
        if (ds == nil) {
            if (data.length > 0) {
                ds = [self _createChannel:ch blobs:blobs error:error];
                if (!ds) return NO;
            } else {
                row[[ch stringByAppendingString:@"_off"]] = @0ULL;
                row[[ch stringByAppendingString:@"_len"]] = @0ULL;
                continue;
            }
        }
        row[[ch stringByAppendingString:@"_off"]] = @((unsigned long long)[ds length]);
        row[[ch stringByAppendingString:@"_len"]] = @((unsigned long long)data.length);
        if (data.length > 0 && ![ds appendData:data error:error]) return NO;
    }
    if (![_indexDs appendData:@[row] error:error]) return NO;
    if (![self _appendIndexArrays:block error:error]) return NO;
    _readCount += blobs.nReads;
    _baseCount += blobs.nBases;
    _blockCount++;
    if (![_rg setAttributeValue:@((int64_t)_readCount) forName:@"read_count" error:error]) return NO;
    if (![_rg setAttributeValue:@((int64_t)_baseCount) forName:@"base_count" error:error]) return NO;
    return YES;
}

- (BOOL)close:(NSError **)error
{
    if (_closed) return YES;
    _closed = YES;
    if (_opt.optLegacyWholeChannel) {
        if (_legacyParts.count > 0) {
            TTIOWrittenGenomicRun *whole =
                [[[self _runWithMeta:[TTIOGenomicBlocks concatRuns:_legacyParts]]
                    copyWithProvenance:_opt.provenanceRecords]
                    copyWithOptLegacyWholeChannel:YES];
            if (_opt.embedReference) {
                if (![TTIOSpectralDataset embedReferencesForRuns:@[whole] inStudy:_study error:error]) return NO;
            }
            id<TTIOStorageGroup> g = [self _runsGroup:error];
            if (!g) return NO;
            if (![TTIOSpectralDataset writeGenomicRunStorage:whole toGroup:g name:_name
                                                     context:[TTIOGenomicWriteContext none]
                                                       error:error]) return NO;
            _readCount = whole.readCount;
        }
        [_legacyParts removeAllObjects];
        [_pool close];
        return YES;
    }
    if (![self _cutBlock:error]) { [_pool close]; return NO; }
    if (![self _drainUntil:0 error:error]) { [_pool close]; return NO; }
    [_pool close];
    if (_rg == nil && ![self _ensureLayout:error]) return NO;
    if (![self _writeCloseTables:error]) return NO;
    if (_opt.provenanceRecords.count > 0) {
        id<TTIOStorageGroup> prov = [_rg createGroupNamed:@"provenance" error:error];
        if (!prov) return NO;
        if ([prov respondsToSelector:@selector(unwrap)]) {
            TTIOHDF5Group *h5 = [(id)prov performSelector:@selector(unwrap)];
            if (h5 && ![TTIOCompoundIO writeProvenance:_opt.provenanceRecords intoGroup:h5
                                          datasetNamed:@"steps" error:error]) return NO;
        }
        NSMutableArray *plists = [NSMutableArray arrayWithCapacity:_opt.provenanceRecords.count];
        for (TTIOProvenanceRecord *r in _opt.provenanceRecords) [plists addObject:[r asPlist]];
        NSError *jErr = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:plists options:0 error:&jErr];
        if (!json) { if (error) *error = jErr; return NO; }
        NSString *jstr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        if (![_rg setAttributeValue:jstr forName:@"provenance_json" error:error]) return NO;
    }
    return YES;
}

// ── layout ───────────────────────────────────────────────────────

- (id<TTIOStorageGroup>)_runsGroup:(NSError **)error
{
    id<TTIOStorageGroup> g;
    if ([_study hasChildNamed:@"genomic_runs"]) {
        g = [_study openGroupNamed:@"genomic_runs" error:error];
        if (!g) return nil;
    } else {
        g = [_study createGroupNamed:@"genomic_runs" error:error];
        if (!g) return nil;
        if (![g setAttributeValue:@"" forName:@"_run_names" error:error]) return nil;
    }
    id namesAttr = [g hasAttributeNamed:@"_run_names"] ? [g attributeValueForName:@"_run_names" error:NULL] : nil;
    NSString *names = namesAttr ? [namesAttr description] : @"";
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *s in [names componentsSeparatedByString:@","]) if (s.length) [list addObject:s];
    if (![list containsObject:_name]) {
        [list addObject:_name];
        if (![g setAttributeValue:[list componentsJoinedByString:@","] forName:@"_run_names" error:error]) return nil;
    }
    return g;
}

- (BOOL)_ensureLayout:(NSError **)error
{
    if (_rg != nil) return YES;
    id<TTIOStorageGroup> g = [self _runsGroup:error];
    if (!g) return NO;
    if ([g hasChildNamed:_name]) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"genomic run '%@' already exists", _name);
        return NO;
    }
    id<TTIOStorageGroup> run = [g createGroupNamed:_name error:error];
    if (!run) return NO;
    if (![run setAttributeValue:@((int64_t)_opt.acquisitionMode) forName:@"acquisition_mode" error:error]) return NO;
    if (![run setAttributeValue:@"genomic_sequencing" forName:@"modality" error:error]) return NO;
    if (![run setAttributeValue:@((int64_t)5) forName:@"spectrum_class" error:error]) return NO;
    if (![run setAttributeValue:_opt.referenceUri ?: @"" forName:@"reference_uri" error:error]) return NO;
    if (![run setAttributeValue:_opt.platform ?: @"" forName:@"platform" error:error]) return NO;
    if (![run setAttributeValue:_opt.sampleName ?: @"" forName:@"sample_name" error:error]) return NO;
    if (![run setAttributeValue:@((int64_t)0) forName:@"read_count" error:error]) return NO;
    if (![run setAttributeValue:@((int64_t)0) forName:@"base_count" error:error]) return NO;
    if (![run setAttributeValue:kLayout forName:@"layout" error:error]) return NO;
    NSString *policy = [NSString stringWithFormat:@"reads=%lu,bytes=%llu",
                        (unsigned long)_opt.blockReads, _opt.blockBytes];
    if (![run setAttributeValue:policy forName:@"block_policy" error:error]) return NO;
    id<TTIOStorageGroup> blocks = [run createGroupNamed:@"blocks" error:error];
    if (!blocks) return NO;
    _indexDs = [blocks createCompoundDatasetNamed:@"index" fields:[[self class] indexFields]
                                            count:0 extendable:YES chunkRows:kIndexChunkRows error:error];
    if (!_indexDs) return NO;
    id<TTIOStorageGroup> idx = [run createGroupNamed:@"genomic_index" error:error];
    if (!idx) return NO;
    NSArray *arrays = @[
        @[@"lengths", @(TTIOPrecisionUInt32)],
        @[@"positions", @(TTIOPrecisionInt64)],
        @[@"mapping_qualities", @(TTIOPrecisionUInt8)],
        @[@"flags", @(TTIOPrecisionUInt32)],
        @[@"chromosome_ids", @(TTIOPrecisionUInt16)],
    ];
    for (NSArray *a in arrays) {
        id<TTIOStorageDataset> ds = [idx createDatasetNamed:a[0]
                                                  precision:(TTIOPrecision)[a[1] integerValue]
                                                     length:0
                                                  chunkSize:kIndexArrayChunk
                                                compression:TTIOCompressionZlib
                                           compressionLevel:6
                                                 extendable:YES
                                                      error:error];
        if (!ds) return NO;
        _idxDs[a[0]] = ds;
    }
    if (![run createGroupNamed:@"signal_channels" error:error]) return NO;
    _rg = run;
    return YES;
}

- (id<TTIOStorageDataset>)_createChannel:(NSString *)ch
                                   blobs:(TTIOBlockBlobs *)blobs
                                   error:(NSError **)error
{
    id<TTIOStorageGroup> sc = [_rg openGroupNamed:@"signal_channels" error:error];
    if (!sc) return nil;
    id<TTIOStorageGroup> parent;
    NSString *dsName;
    if ([ch isEqualToString:@"sequences"]) {
        parent = [sc createGroupNamed:@"sequences" error:error];
        dsName = @"data";
    } else if ([ch isEqualToString:@"mate_info"]) {
        parent = [sc createGroupNamed:@"mate_info" error:error];
        dsName = @"inline_v2";
    } else {
        parent = sc;
        dsName = ch;
    }
    if (!parent) return nil;
    NSUInteger codec = [blobs.codecs[ch] unsignedIntegerValue];
    id<TTIOStorageDataset> ds = [parent createDatasetNamed:dsName
                                                 precision:TTIOPrecisionUInt8
                                                    length:0
                                                 chunkSize:kChannelChunk
                                               compression:codec == 0 ? TTIOCompressionZlib : TTIOCompressionNone
                                          compressionLevel:6
                                                extendable:YES
                                                     error:error];
    if (!ds) return nil;
    if (![ds setAttributeValue:@((int64_t)codec) forName:@"compression" error:error]) return nil;
    NSDictionary *extra = blobs.extraAttrs[ch] ?: @{};
    for (NSString *k in [[extra allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![ds setAttributeValue:extra[k] forName:k error:error]) return nil;
    }
    _channelDs[ch] = ds;
    return ds;
}

- (BOOL)_appendIndexArrays:(TTIOWrittenGenomicRun *)block error:(NSError **)error
{
    NSUInteger n = block.readCount;
    NSMutableData *ids = [NSMutableData dataWithLength:n * sizeof(uint16_t)];
    uint16_t *idv = (uint16_t *)ids.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        NSNumber *id_ = _chromMap[block.chromosomes[i]];
        if (id_ == nil) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"chromosome '%@' missing from the shared id map", block.chromosomes[i]);
            return NO;
        }
        idv[i] = (uint16_t)[id_ unsignedIntegerValue];
    }
    if (![_idxDs[@"lengths"] appendData:block.lengthsData error:error]) return NO;
    if (![_idxDs[@"positions"] appendData:block.positionsData error:error]) return NO;
    if (![_idxDs[@"mapping_qualities"] appendData:block.mappingQualitiesData error:error]) return NO;
    if (![_idxDs[@"flags"] appendData:block.flagsData error:error]) return NO;
    if (![_idxDs[@"chromosome_ids"] appendData:ids error:error]) return NO;
    return YES;
}

- (BOOL)_writeCloseTables:(NSError **)error
{
    NSArray *nameFields = @[[TTIOCompoundField fieldWithName:@"name" kind:TTIOCompoundFieldKindVLString]];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *n in [TTIOGenomicIndex namesInIdOrder:_chromMap]) [rows addObject:@{@"name": n}];
    id<TTIOStorageGroup> idx = [_rg openGroupNamed:@"genomic_index" error:error];
    if (!idx) return NO;
    id<TTIOStorageDataset> ds = [idx createCompoundDatasetNamed:@"chromosome_names"
                                                          fields:nameFields count:rows.count error:error];
    if (!ds || ![ds writeAll:rows error:error]) return NO;
    id<TTIOStorageGroup> sc = [_rg openGroupNamed:@"signal_channels" error:error];
    if (!sc) return NO;
    id<TTIOStorageGroup> mate = [sc hasChildNamed:@"mate_info"]
        ? [sc openGroupNamed:@"mate_info" error:error]
        : [sc createGroupNamed:@"mate_info" error:error];
    if (!mate) return NO;
    if (![mate hasChildNamed:@"chrom_names"]) {
        id<TTIOStorageDataset> cn = [mate createCompoundDatasetNamed:@"chrom_names"
                                                              fields:nameFields count:rows.count error:error];
        if (!cn || ![cn writeAll:rows error:error]) return NO;
    }
    return YES;
}

@end
