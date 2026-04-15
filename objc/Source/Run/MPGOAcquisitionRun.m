#import "MPGOAcquisitionRun.h"
#import "MPGOInstrumentConfig.h"
#import "MPGOSpectrumIndex.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOValueRange.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "HDF5/MPGOHDF5Types.h"

@implementation MPGOAcquisitionRun
{
    NSArray<MPGOMassSpectrum *> *_inMemorySpectra;       // nil when read-from-disk
    MPGOHDF5Group               *_signalChannelsGroup;   // nil when in-memory
    MPGOHDF5Dataset             *_mzDataset;
    MPGOHDF5Dataset             *_intensityDataset;
    NSUInteger                   _streamPosition;
}

- (instancetype)initWithSpectra:(NSArray<MPGOMassSpectrum *> *)spectra
                acquisitionMode:(MPGOAcquisitionMode)mode
               instrumentConfig:(MPGOInstrumentConfig *)config
{
    self = [super init];
    if (self) {
        _inMemorySpectra  = [spectra copy];
        _acquisitionMode  = mode;
        _instrumentConfig = config;
        _spectrumIndex    = [self buildIndexFromSpectra:spectra];
        _streamPosition   = 0;
    }
    return self;
}

- (MPGOSpectrumIndex *)buildIndexFromSpectra:(NSArray<MPGOMassSpectrum *> *)spectra
{
    NSUInteger n = spectra.count;
    NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *rts     = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *ml      = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pol     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pmz     = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *pc      = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *bp      = [NSMutableData dataWithLength:n * sizeof(double)];

    uint64_t *off = offsets.mutableBytes;
    uint32_t *len = lengths.mutableBytes;
    double   *rt  = rts.mutableBytes;
    int32_t  *mlp = ml.mutableBytes;
    int32_t  *plp = pol.mutableBytes;
    double   *pmp = pmz.mutableBytes;
    int32_t  *pcp = pc.mutableBytes;
    double   *bpp = bp.mutableBytes;

    uint64_t cursor = 0;
    for (NSUInteger i = 0; i < n; i++) {
        MPGOMassSpectrum *s = spectra[i];
        off[i] = cursor;
        len[i] = (uint32_t)s.mzArray.length;
        rt[i]  = s.scanTimeSeconds;
        mlp[i] = (int32_t)s.msLevel;
        plp[i] = (int32_t)s.polarity;
        pmp[i] = s.precursorMz;
        pcp[i] = (int32_t)s.precursorCharge;

        // base peak intensity = max(intensity)
        double maxI = 0;
        const double *intP = s.intensityArray.buffer.bytes;
        NSUInteger m = s.intensityArray.length;
        for (NSUInteger j = 0; j < m; j++) if (intP[j] > maxI) maxI = intP[j];
        bpp[i] = maxI;

        cursor += s.mzArray.length;
    }
    return [[MPGOSpectrumIndex alloc] initWithOffsets:offsets
                                              lengths:lengths
                                       retentionTimes:rts
                                             msLevels:ml
                                           polarities:pol
                                         precursorMzs:pmz
                                     precursorCharges:pc
                                  basePeakIntensities:bp];
}

#pragma mark - HDF5 write

- (BOOL)writeToGroup:(MPGOHDF5Group *)parent name:(NSString *)name error:(NSError **)error
{
    NSParameterAssert(_inMemorySpectra != nil);  // disk-backed runs are read-only

    MPGOHDF5Group *runGroup = [parent createGroupNamed:name error:error];
    if (!runGroup) return NO;

    if (![runGroup setIntegerAttribute:@"acquisition_mode"
                                 value:(int64_t)_acquisitionMode error:error]) return NO;
    if (![runGroup setIntegerAttribute:@"spectrum_count"
                                 value:(int64_t)_inMemorySpectra.count error:error]) return NO;

    if (![_instrumentConfig writeToGroup:runGroup error:error]) return NO;
    if (![_spectrumIndex    writeToGroup:runGroup error:error]) return NO;

    // Concatenate all mz / intensity buffers into two contiguous datasets.
    NSUInteger total = 0;
    for (MPGOMassSpectrum *s in _inMemorySpectra) total += s.mzArray.length;

    NSMutableData *mzAll = [NSMutableData dataWithLength:total * sizeof(double)];
    NSMutableData *inAll = [NSMutableData dataWithLength:total * sizeof(double)];
    NSUInteger cursor = 0;
    for (MPGOMassSpectrum *s in _inMemorySpectra) {
        NSUInteger n = s.mzArray.length;
        memcpy((uint8_t *)mzAll.mutableBytes + cursor * sizeof(double),
               s.mzArray.buffer.bytes, n * sizeof(double));
        memcpy((uint8_t *)inAll.mutableBytes + cursor * sizeof(double),
               s.intensityArray.buffer.bytes, n * sizeof(double));
        cursor += n;
    }

    MPGOHDF5Group *channels = [runGroup createGroupNamed:@"signal_channels" error:error];
    if (!channels) return NO;

    MPGOHDF5Dataset *mzDS = [channels createDatasetNamed:@"mz_values"
                                                precision:MPGOPrecisionFloat64
                                                   length:total
                                                chunkSize:16384
                                         compressionLevel:6
                                                    error:error];
    if (!mzDS) return NO;
    if (![mzDS writeData:mzAll error:error]) return NO;

    MPGOHDF5Dataset *inDS = [channels createDatasetNamed:@"intensity_values"
                                                precision:MPGOPrecisionFloat64
                                                   length:total
                                                chunkSize:16384
                                         compressionLevel:6
                                                    error:error];
    if (!inDS) return NO;
    if (![inDS writeData:inAll error:error]) return NO;

    return YES;
}

#pragma mark - HDF5 read

+ (instancetype)readFromGroup:(MPGOHDF5Group *)parent name:(NSString *)name error:(NSError **)error
{
    MPGOHDF5Group *runGroup = [parent openGroupNamed:name error:error];
    if (!runGroup) return nil;

    BOOL exists = NO;
    MPGOAcquisitionMode mode =
        (MPGOAcquisitionMode)[runGroup integerAttributeNamed:@"acquisition_mode"
                                                       exists:&exists error:error];

    MPGOInstrumentConfig *cfg = [MPGOInstrumentConfig readFromGroup:runGroup error:error];
    if (!cfg) return nil;

    MPGOSpectrumIndex *idx = [MPGOSpectrumIndex readFromGroup:runGroup error:error];
    if (!idx) return nil;

    MPGOHDF5Group *channels = [runGroup openGroupNamed:@"signal_channels" error:error];
    if (!channels) return nil;
    MPGOHDF5Dataset *mzDS = [channels openDatasetNamed:@"mz_values" error:error];
    MPGOHDF5Dataset *inDS = [channels openDatasetNamed:@"intensity_values" error:error];
    if (!mzDS || !inDS) return nil;

    MPGOAcquisitionRun *run = [[self alloc] init];
    run->_acquisitionMode      = mode;
    run->_instrumentConfig     = cfg;
    run->_spectrumIndex        = idx;
    run->_signalChannelsGroup  = channels;
    run->_mzDataset            = mzDS;
    run->_intensityDataset     = inDS;
    run->_inMemorySpectra      = nil;
    run->_streamPosition       = 0;
    return run;
}

#pragma mark - Random access

- (MPGOMassSpectrum *)spectrumAtIndex:(NSUInteger)index error:(NSError **)error
{
    if (_inMemorySpectra) {
        if (index >= _inMemorySpectra.count) {
            if (error) *error = MPGOMakeError(MPGOErrorOutOfRange,
                @"index %lu beyond spectrum count %lu",
                (unsigned long)index, (unsigned long)_inMemorySpectra.count);
            return nil;
        }
        return _inMemorySpectra[index];
    }

    if (index >= _spectrumIndex.count) {
        if (error) *error = MPGOMakeError(MPGOErrorOutOfRange,
            @"index %lu beyond spectrum count %lu",
            (unsigned long)index, (unsigned long)_spectrumIndex.count);
        return nil;
    }

    uint64_t off = [_spectrumIndex offsetAt:index];
    uint32_t len = [_spectrumIndex lengthAt:index];

    NSData *mz = [_mzDataset readDataAtOffset:(NSUInteger)off
                                         count:(NSUInteger)len
                                         error:error];
    if (!mz) return nil;
    NSData *in = [_intensityDataset readDataAtOffset:(NSUInteger)off
                                                count:(NSUInteger)len
                                                error:error];
    if (!in) return nil;

    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    MPGOSignalArray *mzA = [[MPGOSignalArray alloc] initWithBuffer:mz
                                                            length:len
                                                          encoding:enc
                                                              axis:nil];
    MPGOSignalArray *inA = [[MPGOSignalArray alloc] initWithBuffer:in
                                                            length:len
                                                          encoding:enc
                                                              axis:nil];

    return [[MPGOMassSpectrum alloc]
            initWithMzArray:mzA
             intensityArray:inA
                    msLevel:[_spectrumIndex msLevelAt:index]
                   polarity:[_spectrumIndex polarityAt:index]
                 scanWindow:nil
              indexPosition:index
            scanTimeSeconds:[_spectrumIndex retentionTimeAt:index]
                precursorMz:[_spectrumIndex precursorMzAt:index]
            precursorCharge:[_spectrumIndex precursorChargeAt:index]
                      error:error];
}

- (NSArray<NSNumber *> *)indicesInRetentionTimeRange:(MPGOValueRange *)range
{
    NSIndexSet *set = [_spectrumIndex indicesInRetentionTimeRange:range];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:set.count];
    NSUInteger idx = [set firstIndex];
    while (idx != NSNotFound) {
        [out addObject:@(idx)];
        idx = [set indexGreaterThanIndex:idx];
    }
    return out;
}

#pragma mark - MPGOIndexable

- (id)objectAtIndex:(NSUInteger)index
{
    return [self spectrumAtIndex:index error:NULL];
}

- (NSUInteger)count
{
    return _inMemorySpectra ? _inMemorySpectra.count : _spectrumIndex.count;
}

- (NSArray *)objectsInRange:(NSRange)range
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:range.length];
    for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
        id obj = [self objectAtIndex:i];
        if (obj) [out addObject:obj];
    }
    return out;
}

#pragma mark - MPGOStreamable

- (id)nextObject
{
    if (![self hasMore]) return nil;
    id obj = [self objectAtIndex:_streamPosition];
    _streamPosition++;
    return obj;
}

- (BOOL)hasMore               { return _streamPosition < [self count]; }
- (NSUInteger)currentPosition { return _streamPosition; }
- (BOOL)seekToPosition:(NSUInteger)position
{
    if (position > [self count]) return NO;
    _streamPosition = position;
    return YES;
}
- (void)reset                 { _streamPosition = 0; }

@end
