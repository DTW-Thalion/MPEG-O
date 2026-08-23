/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "Run/TTIOSpectralStreamWriter.h"
#import "Core/TTIOThreads.h"
#import "Run/TTIOWrittenSpectralBatch.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Codecs/TTIOFloatDeltaZstd.h"
#import "Dataset/TTIOCompoundIO.h"
#import "Providers/TTIOCompoundField.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Types.h"

static const NSUInteger kDefaultBatchSpectra = 4096;
static const NSUInteger kIndexChunk = 4096;
static const NSUInteger kChannelChunk = 65536;

@implementation TTIOSpectralStreamWriterOptions

- (instancetype)init
{
    self = [super init];
    if (self) {
        _spectrumClass = @"TTIOMassSpectrum";
        _channelNames = @[];
        _batchSpectra = kDefaultBatchSpectra;
        _signalCompression = TTIOCompressionZlib;
        _solvent = @"";
        _provenanceRecords = @[];
    }
    return self;
}

+ (instancetype)msOptionsWithMode:(TTIOAcquisitionMode)mode
                     channelNames:(NSArray<NSString *> *)channelNames
                 instrumentConfig:(TTIOInstrumentConfig *)config
{
    TTIOSpectralStreamWriterOptions *o = [[self alloc] init];
    o.acquisitionMode = mode;
    o.channelNames = channelNames;
    o.instrumentConfig = config;
    return o;
}

- (id)copyWithZone:(NSZone *)zone
{
    TTIOSpectralStreamWriterOptions *o = [[[self class] allocWithZone:zone] init];
    o.spectrumClass = _spectrumClass;
    o.acquisitionMode = _acquisitionMode;
    o.channelNames = _channelNames;
    o.instrumentConfig = _instrumentConfig;
    o.batchSpectra = _batchSpectra;
    o.optDisableFloatDelta = _optDisableFloatDelta;
    o.signalCompression = _signalCompression;
    o.nucleusType = _nucleusType;
    o.solvent = _solvent;
    o.provenanceRecords = _provenanceRecords;
    o.threads = _threads;
    return o;
}

@end

typedef struct { NSString *name; TTIOPrecision precision; } TTIOIndexColumnSpec;

/** One codec-17 block in flight for one channel. */
@interface TTIOInFlightFdz : NSObject
@property (nonatomic, strong, nullable) NSData *encoded;
@property (nonatomic) NSUInteger nValues;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic) BOOL done;
@end

@implementation TTIOInFlightFdz
@end

@implementation TTIOSpectralStreamWriter {
    NSUInteger _threads;
    TTIOThreadPool *_pool;
    NSMutableDictionary<NSString *, NSMutableArray<TTIOInFlightFdz *> *> *_fdzInflight;
    NSCondition *_fdzCond;
    id<TTIOStorageGroup> _study;
    NSString *_name;
    TTIOSpectralStreamWriterOptions *_opt;
    BOOL _useFloatDelta;
    id<TTIOStorageGroup> _rg;
    id<TTIOStorageGroup> _idxGroup;
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *_idx;
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *_sig;
    NSMutableDictionary<NSString *, NSMutableData *> *_fdzBuf;
    NSMutableDictionary<NSString *, NSNumber *> *_fdzValues;
    NSMutableDictionary<NSString *, NSNumber *> *_fdzBlocks;
    /** One row per block ordinal, filled in as each channel's block
     *  lands, written to blocks/index at close. */
    NSMutableArray<NSMutableDictionary<NSString *, id> *> *_blockRows;
    BOOL _m74;
    BOOL _centroided;
    NSUInteger _count;
    NSArray<TTIOChromatogram *> *_chromatograms;
    NSMutableArray<TTIOSpectrum *> *_pending;
    BOOL _closed;
}

static NSArray *ttioIndexColumns(void)
{
    return @[@[@"lengths", @(TTIOPrecisionUInt32)], @[@"retention_times", @(TTIOPrecisionFloat64)],
             @[@"ms_levels", @(TTIOPrecisionInt32)], @[@"polarities", @(TTIOPrecisionInt32)],
             @[@"precursor_mzs", @(TTIOPrecisionFloat64)], @[@"precursor_charges", @(TTIOPrecisionInt32)],
             @[@"base_peak_intensities", @(TTIOPrecisionFloat64)]];
}

/* The blocks/index row, mirroring the genomic run's: where every
 * channel's block for one value range lives, so a consumer can plan a
 * range read or a parallel decode from one compound read instead of
 * walking each FDZ1 stream's block headers. */
static NSArray<TTIOCompoundField *> *ttioBlockIndexFields(NSArray<NSString *> *channels)
{
    NSMutableArray *f = [NSMutableArray array];
    [f addObject:[TTIOCompoundField fieldWithName:@"value_start" kind:TTIOCompoundFieldKindUInt64]];
    [f addObject:[TTIOCompoundField fieldWithName:@"n_values" kind:TTIOCompoundFieldKindUInt32]];
    for (NSString *c in channels) {
        [f addObject:[TTIOCompoundField fieldWithName:[c stringByAppendingString:@"_off"]
                                                 kind:TTIOCompoundFieldKindUInt64]];
        [f addObject:[TTIOCompoundField fieldWithName:[c stringByAppendingString:@"_len"]
                                                 kind:TTIOCompoundFieldKindUInt64]];
    }
    for (NSString *c in channels) {
        [f addObject:[TTIOCompoundField fieldWithName:[c stringByAppendingString:@"_codec"]
                                                 kind:TTIOCompoundFieldKindUInt32]];
    }
    return f;
}

static NSArray *ttioM74Columns(void)
{
    return @[@[@"activation_methods", @(TTIOPrecisionInt32)], @[@"isolation_target_mzs", @(TTIOPrecisionFloat64)],
             @[@"isolation_lower_offsets", @(TTIOPrecisionFloat64)], @[@"isolation_upper_offsets", @(TTIOPrecisionFloat64)]];
}

- (instancetype)initWithStudyGroup:(id<TTIOStorageGroup>)study
                           runName:(NSString *)runName
                           options:(TTIOSpectralStreamWriterOptions *)options
{
    self = [super init];
    if (self) {
        _study = study;
        _name = [runName copy];
        _opt = [options copy];
        if (_opt.batchSpectra < 1) _opt.batchSpectra = 1;
        _useFloatDelta = _opt.signalCompression == TTIOCompressionFloatDeltaZstd
            || (_opt.signalCompression == TTIOCompressionZlib && !_opt.optDisableFloatDelta
                && [_opt.spectrumClass isEqualToString:@"TTIOMassSpectrum"]);
        _idx = [NSMutableDictionary dictionary];
        _sig = [NSMutableDictionary dictionary];
        _fdzBuf = [NSMutableDictionary dictionary];
        _threads = [TTIOThreads resolve:_opt.threads ? @(_opt.threads) : nil];
        _pool = [TTIOThreadPool poolWithThreads:_threads];
        _fdzInflight = [NSMutableDictionary dictionary];
        _fdzCond = [NSCondition new];
        _fdzValues = [NSMutableDictionary dictionary];
        _fdzBlocks = [NSMutableDictionary dictionary];
        _blockRows = [NSMutableArray array];
        _pending = [NSMutableArray array];
        _chromatograms = @[];
    }
    return self;
}

- (NSUInteger)spectrumCount { return _count + _pending.count; }

- (void)setChromatograms:(NSArray<TTIOChromatogram *> *)chromatograms
{
    _chromatograms = [chromatograms copy] ?: @[];
}

- (BOOL)appendSpectrum:(TTIOSpectrum *)spectrum error:(NSError **)error
{
    if (_closed) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"spectral stream writer is closed");
        return NO;
    }
    [_pending addObject:spectrum];
    if (_pending.count >= _opt.batchSpectra) return [self flush:error];
    return YES;
}

- (BOOL)appendBatch:(TTIOWrittenSpectralBatch *)batch error:(NSError **)error
{
    if (_closed) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"spectral stream writer is closed");
        return NO;
    }
    if (![self flush:error]) return NO;
    if (batch.spectrumCount > 0) return [self _writeBatch:batch error:error];
    return YES;
}

- (NSUInteger)threads { return _threads; }

/** Append completed blocks of a channel in emission order; wait on the
 *  oldest until at most blockUntil remain in flight. */
- (BOOL)_drainFdz:(NSString *)c until:(NSUInteger)blockUntil error:(NSError **)error
{
    NSMutableArray<TTIOInFlightFdz *> *q = _fdzInflight[c];
    if (!q) return YES;
    while (q.count > 0) {
        TTIOInFlightFdz *f = q.firstObject;
        [_fdzCond lock];
        if (q.count <= blockUntil && !f.done) {
            [_fdzCond unlock];
            break;
        }
        while (!f.done) [_fdzCond wait];
        [_fdzCond unlock];
        [q removeObjectAtIndex:0];
        if (!f.encoded) {
            if (error) *error = f.error ?: TTIOMakeError(TTIOErrorDatasetWrite,
                @"FLOAT_DELTA_ZSTD block encode failed for '%@'", c);
            return NO;
        }
        if (![self _appendFdz:c encoded:f.encoded nValues:f.nValues error:error]) return NO;
    }
    return YES;
}

- (BOOL)_appendFdz:(NSString *)c encoded:(NSData *)encoded nValues:(NSUInteger)nValues error:(NSError **)error
{
    /* The block lands at the current end of the channel dataset. The
     * recorded extent covers the 5-byte block header as well as the
     * body, so one range read yields a self-describing block. */
    uint64_t off = (uint64_t)[_sig[c] length];
    NSUInteger ordinal = [_fdzBlocks[c] unsignedIntegerValue];
    uint64_t valueStart = [_fdzValues[c] unsignedLongLongValue];
    if (![_sig[c] appendData:encoded error:error]) return NO;
    _fdzValues[c] = @(valueStart + nValues);
    _fdzBlocks[c] = @(ordinal + 1);

    while (_blockRows.count <= ordinal) {
        [_blockRows addObject:[NSMutableDictionary dictionary]];
    }
    NSMutableDictionary *row = _blockRows[ordinal];
    row[@"value_start"] = @(valueStart);
    row[@"n_values"] = @((uint32_t)nValues);
    row[[c stringByAppendingString:@"_off"]] = @(off);
    row[[c stringByAppendingString:@"_len"]] = @((uint64_t)encoded.length);
    row[[c stringByAppendingString:@"_codec"]] = @((uint32_t)TTIOCompressionFloatDeltaZstd);
    return YES;
}

/* blocks/index describes one value range per row, so it is only
 * meaningful when every channel cut its blocks at the same points.
 * They do when each spectrum contributes one value per channel, which
 * is every case the writer produces today; a run that ever fell out of
 * step gets no table rather than a wrong one. */
- (BOOL)_writeBlockIndex:(NSError **)error
{
    if (!_useFloatDelta || _blockRows.count == 0) return YES;
    NSArray<NSString *> *channels = _opt.channelNames;
    for (NSMutableDictionary *row in _blockRows) {
        for (NSString *c in channels) {
            if (!row[[c stringByAppendingString:@"_off"]]) return YES;
        }
    }
    id<TTIOStorageGroup> blocks = [_rg createGroupNamed:@"blocks" error:error];
    if (!blocks) return NO;
    /* Every row is known here, so the chunk is sized to them: a
     * fixed 256-row chunk costs a run with one block 13 KB of padding,
     * which dominates a small .tio. */
    NSUInteger chunkRows = MIN(MAX(_blockRows.count, (NSUInteger)1), (NSUInteger)1024);
    id<TTIOStorageDataset> ds =
        [blocks createCompoundDatasetNamed:@"index"
                                    fields:ttioBlockIndexFields(channels)
                                     count:0
                                extendable:YES
                                 chunkRows:chunkRows
                                     error:error];
    if (!ds) return NO;
    return [ds appendData:_blockRows error:error];
}

- (BOOL)flush:(NSError **)error
{
    if (_pending.count == 0) return YES;
    TTIOWrittenSpectralBatch *b = [TTIOWrittenSpectralBatch batchWithSpectra:_pending channelNames:_opt.channelNames];
    [_pending removeAllObjects];
    return [self _writeBatch:b error:error];
}

- (BOOL)close:(NSError **)error
{
    if (_closed) return YES;
    _closed = YES;
    if (![self flush:error]) return NO;
    if (_rg == nil && ![self _ensureLayout:nil error:error]) return NO;
    if (_useFloatDelta) {
        for (NSString *c in _opt.channelNames) {
            NSMutableData *buf = _fdzBuf[c];
            if (buf.length > 0 && ![self _emitFdzBlock:c values:buf error:error]) return NO;
            _fdzBuf[c] = [NSMutableData data];
            if (![self _drainFdz:c until:0 error:error]) return NO;
            NSData *hdr = [TTIOFloatDeltaZstd headerBytesForValues:[_fdzValues[c] unsignedLongLongValue]
                                                             blocks:(uint32_t)[_fdzBlocks[c] unsignedIntegerValue]];
            if (![_sig[c] writeSlice:hdr atOffset:0 error:error]) return NO;
        }
        if (![self _writeBlockIndex:error]) return NO;
    }
    if (![_rg setAttributeValue:@((int64_t)_count) forName:@"spectrum_count" error:error]) return NO;
    if (![_idxGroup setAttributeValue:@((int64_t)_count) forName:@"count" error:error]) return NO;
    if (_chromatograms.count > 0
        && ![TTIOAcquisitionRun writeChromatograms:_chromatograms toRunGroup:_rg error:error]) return NO;
    if (_opt.provenanceRecords.count > 0
        && ![TTIOAcquisitionRun writeProvenance:_opt.provenanceRecords toRunGroup:_rg error:error]) return NO;
    [_pool close];
    return YES;
}

// ── layout ───────────────────────────────────────────────────────

- (id<TTIOStorageGroup>)_runsGroup:(NSError **)error
{
    id<TTIOStorageGroup> g;
    if ([_study hasChildNamed:@"ms_runs"]) {
        g = [_study openGroupNamed:@"ms_runs" error:error];
        if (!g) return nil;
    } else {
        g = [_study createGroupNamed:@"ms_runs" error:error];
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

- (BOOL)_createIndexColumn:(NSString *)name precision:(TTIOPrecision)p error:(NSError **)error
{
    id<TTIOStorageDataset> ds = [_idxGroup createDatasetNamed:name precision:p length:0 chunkSize:kIndexChunk
                                                  compression:TTIOCompressionZlib compressionLevel:6
                                                   extendable:YES error:error];
    if (!ds) return NO;
    _idx[name] = ds;
    return YES;
}

- (BOOL)_ensureLayout:(TTIOWrittenSpectralBatch *)first error:(NSError **)error
{
    if (_rg != nil) return YES;
    id<TTIOStorageGroup> parent = [self _runsGroup:error];
    if (!parent) return NO;
    if ([parent hasChildNamed:_name]) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"run '%@' already exists", _name);
        return NO;
    }
    id<TTIOStorageGroup> g = [parent createGroupNamed:_name error:error];
    if (!g) return NO;
    if (![g setAttributeValue:@((int64_t)_opt.acquisitionMode) forName:@"acquisition_mode" error:error]) return NO;
    if (![g setAttributeValue:@((int64_t)0) forName:@"spectrum_count" error:error]) return NO;
    if (![g setAttributeValue:_opt.spectrumClass forName:@"spectrum_class" error:error]) return NO;
    if (_opt.nucleusType && ![g setAttributeValue:_opt.nucleusType forName:@"nucleus_type" error:error]) return NO;
    if (_opt.solvent.length && ![g setAttributeValue:_opt.solvent forName:@"solvent" error:error]) return NO;
    TTIOInstrumentConfig *cfg = _opt.instrumentConfig
        ?: [[TTIOInstrumentConfig alloc] initWithManufacturer:@"" model:@"" serialNumber:@""
                                                   sourceType:@"" analyzerType:@"" detectorType:@""];
    if (![cfg writeToGroup:g error:error]) return NO;
    _idxGroup = [g createGroupNamed:@"spectrum_index" error:error];
    if (!_idxGroup) return NO;
    if (![_idxGroup setAttributeValue:@((int64_t)0) forName:@"count" error:error]) return NO;
    for (NSArray *c in ttioIndexColumns()) {
        if (![self _createIndexColumn:c[0] precision:(TTIOPrecision)[c[1] integerValue] error:error]) return NO;
    }
    if (first != nil && first.hasM74) {
        _m74 = YES;
        for (NSArray *c in ttioM74Columns()) {
            if (![self _createIndexColumn:c[0] precision:(TTIOPrecision)[c[1] integerValue] error:error]) return NO;
        }
    }
    if (first != nil && first.centroideds != nil) {
        _centroided = YES;
        if (![self _createIndexColumn:@"centroideds" precision:TTIOPrecisionInt32 error:error]) return NO;
    }
    id<TTIOStorageGroup> sc = [g createGroupNamed:@"signal_channels" error:error];
    if (!sc) return NO;
    if (![sc setAttributeValue:[_opt.channelNames componentsJoinedByString:@","]
                       forName:@"channel_names" error:error]) return NO;
    for (NSString *c in _opt.channelNames) {
        NSString *dsName = [c stringByAppendingString:@"_values"];
        id<TTIOStorageDataset> ds;
        if (_useFloatDelta) {
            ds = [sc createDatasetNamed:dsName precision:TTIOPrecisionUInt8 length:0 chunkSize:kChannelChunk
                            compression:TTIOCompressionNone compressionLevel:0 extendable:YES error:error];
            if (!ds) return NO;
            if (![ds setAttributeValue:@(TTIOCompressionFloatDeltaZstd) forName:@"compression" error:error]) return NO;
            if (![ds appendData:[TTIOFloatDeltaZstd headerBytesForValues:0 blocks:0] error:error]) return NO;
            _fdzBuf[c] = [NSMutableData data];
            _fdzValues[c] = @0;
            _fdzBlocks[c] = @0;
        } else {
            TTIOCompression codec = _opt.signalCompression == TTIOCompressionZlib
                ? TTIOCompressionZlib : TTIOCompressionNone;
            ds = [sc createDatasetNamed:dsName precision:TTIOPrecisionFloat64 length:0 chunkSize:kChannelChunk
                            compression:codec compressionLevel:6 extendable:YES error:error];
            if (!ds) return NO;
        }
        _sig[c] = ds;
    }
    _rg = g;
    return YES;
}

static NSData *ttioZeros(TTIOPrecision p, NSUInteger n)
{
    return [NSMutableData dataWithLength:n * TTIOPrecisionElementSize(p)];
}

- (BOOL)_writeBatch:(TTIOWrittenSpectralBatch *)b error:(NSError **)error
{
    if (![self _ensureLayout:b error:error]) return NO;
    NSUInteger n = b.spectrumCount;
    if (b.hasM74 && !_m74) {
        _m74 = YES;
        for (NSArray *c in ttioM74Columns()) {
            TTIOPrecision p = (TTIOPrecision)[c[1] integerValue];
            if (![self _createIndexColumn:c[0] precision:p error:error]) return NO;
            if (_count > 0 && ![_idx[c[0]] appendData:ttioZeros(p, _count) error:error]) return NO;
        }
    }
    if (b.centroideds != nil && !_centroided) {
        _centroided = YES;
        if (![self _createIndexColumn:@"centroideds" precision:TTIOPrecisionInt32 error:error]) return NO;
        if (_count > 0 && ![_idx[@"centroideds"] appendData:ttioZeros(TTIOPrecisionInt32, _count) error:error]) return NO;
    }
    if (![_idx[@"lengths"] appendData:b.lengths error:error]) return NO;
    if (![_idx[@"retention_times"] appendData:b.retentionTimes error:error]) return NO;
    if (![_idx[@"ms_levels"] appendData:b.msLevels error:error]) return NO;
    if (![_idx[@"polarities"] appendData:b.polarities error:error]) return NO;
    if (![_idx[@"precursor_mzs"] appendData:b.precursorMzs error:error]) return NO;
    if (![_idx[@"precursor_charges"] appendData:b.precursorCharges error:error]) return NO;
    if (![_idx[@"base_peak_intensities"] appendData:b.basePeakIntensities error:error]) return NO;
    if (_m74) {
        BOOL h = b.hasM74;
        if (![_idx[@"activation_methods"] appendData:h ? b.activationMethods : ttioZeros(TTIOPrecisionInt32, n) error:error]) return NO;
        if (![_idx[@"isolation_target_mzs"] appendData:h ? b.isolationTargetMzs : ttioZeros(TTIOPrecisionFloat64, n) error:error]) return NO;
        if (![_idx[@"isolation_lower_offsets"] appendData:h ? b.isolationLowerOffsets : ttioZeros(TTIOPrecisionFloat64, n) error:error]) return NO;
        if (![_idx[@"isolation_upper_offsets"] appendData:h ? b.isolationUpperOffsets : ttioZeros(TTIOPrecisionFloat64, n) error:error]) return NO;
    }
    if (_centroided) {
        if (![_idx[@"centroideds"] appendData:b.centroideds ?: ttioZeros(TTIOPrecisionInt32, n) error:error]) return NO;
    }
    NSUInteger blockSize = [TTIOFloatDeltaZstd blockSize];
    for (NSString *c in _opt.channelNames) {
        NSData *data = b.channelData[c] ?: [NSData data];
        if (_useFloatDelta) {
            NSMutableData *buf = _fdzBuf[c];
            [buf appendData:data];
            NSUInteger pos = 0;
            NSUInteger nVals = buf.length / sizeof(double);
            while (nVals - pos >= blockSize) {
                NSData *slice = [buf subdataWithRange:NSMakeRange(pos * sizeof(double), blockSize * sizeof(double))];
                if (![self _emitFdzBlock:c values:slice error:error]) return NO;
                pos += blockSize;
            }
            if (pos > 0) {
                _fdzBuf[c] = [NSMutableData dataWithData:
                    [buf subdataWithRange:NSMakeRange(pos * sizeof(double), buf.length - pos * sizeof(double))]];
            }
        } else {
            if (![_sig[c] appendData:data error:error]) return NO;
        }
    }
    _count += n;
    if (![_rg setAttributeValue:@((int64_t)_count) forName:@"spectrum_count" error:error]) return NO;
    if (![_idxGroup setAttributeValue:@((int64_t)_count) forName:@"count" error:error]) return NO;
    return YES;
}

- (BOOL)_emitFdzBlock:(NSString *)c values:(NSData *)values error:(NSError **)error
{
    NSUInteger nValues = values.length / sizeof(double);
    if (_pool.queue == nil) {
        TTIOFDZEncodedBlock *b = [TTIOFloatDeltaZstd encodeBlock:values];
        if (!b) {
            if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite, @"FLOAT_DELTA_ZSTD block encode failed for '%@'", c);
            return NO;
        }
        return [self _appendFdz:c encoded:[TTIOFloatDeltaZstd blockBytes:b] nValues:nValues error:error];
    }
    if (![self _drainFdz:c until:_threads error:error]) return NO;
    if (!_fdzInflight[c]) _fdzInflight[c] = [NSMutableArray array];
    TTIOInFlightFdz *f = [TTIOInFlightFdz new];
    f.nValues = nValues;
    [_fdzInflight[c] addObject:f];
    NSData *copy = [values copy];   /* the caller reuses its buffer */
    NSCondition *cond = _fdzCond;
    [_pool.queue addOperationWithBlock:^{
        TTIOFDZEncodedBlock *b = nil;
        @try {
            b = [TTIOFloatDeltaZstd encodeBlock:copy];
        } @catch (NSException *ex) {
            b = nil;
        }
        [cond lock];
        f.encoded = b ? [TTIOFloatDeltaZstd blockBytes:b] : nil;
        f.done = YES;
        [cond broadcast];
        [cond unlock];
    }];
    return YES;
}

@end
