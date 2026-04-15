#import "MPGOAcquisitionRun.h"
#import "MPGOInstrumentConfig.h"
#import "MPGOSpectrumIndex.h"
#import "Spectra/MPGOSpectrum.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOValueRange.h"
#import "Dataset/MPGOProvenanceRecord.h"
#import "Protection/MPGOEncryptionManager.h"
#import "Protection/MPGOAccessPolicy.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "HDF5/MPGOHDF5Types.h"

@implementation MPGOAcquisitionRun
{
    NSArray                     *_inMemorySpectra;       // nil when read-from-disk
    MPGOHDF5Group               *_signalChannelsGroup;   // nil when in-memory
    NSMutableDictionary<NSString *, MPGOHDF5Dataset *> *_channelDatasets;
    NSArray<NSString *>         *_channelNames;          // ordered list
    NSUInteger                   _streamPosition;

    NSMutableArray<MPGOProvenanceRecord *> *_provenance;
    MPGOAccessPolicy            *_accessPolicy;

    // Persistence context attached post-load for protocol encryption
    NSString *_persistenceFilePath;
    NSString *_persistenceRunName;
}

#pragma mark - Construction

- (instancetype)initWithSpectra:(NSArray *)spectra
                acquisitionMode:(MPGOAcquisitionMode)mode
               instrumentConfig:(MPGOInstrumentConfig *)config
{
    self = [super init];
    if (self) {
        _inMemorySpectra  = [spectra copy];
        _acquisitionMode  = mode;
        _instrumentConfig = config;
        _streamPosition   = 0;
        _provenance       = [NSMutableArray array];

        if (spectra.count > 0) {
            MPGOSpectrum *first = spectra[0];
            _spectrumClassName = NSStringFromClass([first class]);
            _channelNames = [[first.signalArrays allKeys]
                sortedArrayUsingSelector:@selector(compare:)];

            if ([first isKindOfClass:[MPGONMRSpectrum class]]) {
                MPGONMRSpectrum *n = (MPGONMRSpectrum *)first;
                _nucleusType = [n.nucleusType copy];
                _spectrometerFrequencyMHz = n.spectrometerFrequencyMHz;
            }
        } else {
            _spectrumClassName = @"MPGOMassSpectrum";
            _channelNames = @[@"mz", @"intensity"];
        }

        _spectrumIndex = [self buildIndexFromSpectra:spectra];
    }
    return self;
}

#pragma mark - Index construction

- (MPGOSpectrumIndex *)buildIndexFromSpectra:(NSArray *)spectra
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

    NSString *firstChannel = _channelNames.firstObject;
    uint64_t cursor = 0;
    for (NSUInteger i = 0; i < n; i++) {
        MPGOSpectrum *s = spectra[i];
        MPGOSignalArray *primary = s.signalArrays[firstChannel];
        off[i] = cursor;
        len[i] = (uint32_t)primary.length;
        rt[i]  = s.scanTimeSeconds;
        pmp[i] = s.precursorMz;
        pcp[i] = (int32_t)s.precursorCharge;

        if ([s isKindOfClass:[MPGOMassSpectrum class]]) {
            MPGOMassSpectrum *ms = (MPGOMassSpectrum *)s;
            mlp[i] = (int32_t)ms.msLevel;
            plp[i] = (int32_t)ms.polarity;

            double maxI = 0;
            MPGOSignalArray *inA = ms.intensityArray;
            const double *intP = inA.buffer.bytes;
            NSUInteger m = inA.length;
            for (NSUInteger j = 0; j < m; j++) if (intP[j] > maxI) maxI = intP[j];
            bpp[i] = maxI;
        } else {
            // NMR or other non-MS spectra: sentinel values.
            mlp[i] = 0;
            plp[i] = (int32_t)MPGOPolarityUnknown;

            double maxI = 0;
            MPGOSignalArray *inA = s.signalArrays[@"intensity"];
            if (inA) {
                const double *intP = inA.buffer.bytes;
                NSUInteger m = inA.length;
                for (NSUInteger j = 0; j < m; j++) if (intP[j] > maxI) maxI = intP[j];
            }
            bpp[i] = maxI;
        }

        cursor += primary.length;
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
    if (![runGroup setStringAttribute:@"spectrum_class"
                                value:_spectrumClassName error:error]) return NO;

    if (_nucleusType) {
        if (![runGroup setStringAttribute:@"nucleus_type"
                                    value:_nucleusType error:error]) return NO;
        MPGOHDF5Dataset *fd = [runGroup createDatasetNamed:@"_spectrometer_freq_mhz"
                                                 precision:MPGOPrecisionFloat64
                                                    length:1
                                                 chunkSize:0
                                          compressionLevel:0
                                                     error:error];
        if (!fd) return NO;
        double f[1] = { _spectrometerFrequencyMHz };
        if (![fd writeData:[NSData dataWithBytes:f length:sizeof(f)] error:error]) return NO;
    }

    // Per-run provenance as a single JSON-encoded attribute
    if (_provenance.count > 0) {
        NSMutableArray *plists = [NSMutableArray arrayWithCapacity:_provenance.count];
        for (MPGOProvenanceRecord *r in _provenance) [plists addObject:[r asPlist]];
        NSError *jErr = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:plists options:0 error:&jErr];
        if (!json) {
            if (error) *error = jErr;
            return NO;
        }
        NSString *jstr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        if (![runGroup setStringAttribute:@"provenance_json"
                                    value:jstr error:error]) return NO;
    }

    if (![_instrumentConfig writeToGroup:runGroup error:error]) return NO;
    if (![_spectrumIndex    writeToGroup:runGroup error:error]) return NO;

    MPGOHDF5Group *channels = [runGroup createGroupNamed:@"signal_channels" error:error];
    if (!channels) return NO;

    NSString *namesJoined = [_channelNames componentsJoinedByString:@","];
    if (![channels setStringAttribute:@"channel_names"
                                value:namesJoined error:error]) return NO;

    NSUInteger total = 0;
    for (MPGOSpectrum *s in _inMemorySpectra) {
        total += [s.signalArrays[_channelNames.firstObject] length];
    }

    for (NSString *chName in _channelNames) {
        NSMutableData *all = [NSMutableData dataWithLength:total * sizeof(double)];
        NSUInteger cursor = 0;
        for (MPGOSpectrum *s in _inMemorySpectra) {
            MPGOSignalArray *arr = s.signalArrays[chName];
            NSUInteger n = arr.length;
            memcpy((uint8_t *)all.mutableBytes + cursor * sizeof(double),
                   arr.buffer.bytes, n * sizeof(double));
            cursor += n;
        }
        NSString *dsName = [chName stringByAppendingString:@"_values"];
        MPGOHDF5Dataset *ds = [channels createDatasetNamed:dsName
                                                 precision:MPGOPrecisionFloat64
                                                    length:total
                                                 chunkSize:16384
                                          compressionLevel:6
                                                     error:error];
        if (!ds) return NO;
        if (![ds writeData:all error:error]) return NO;
    }

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

    // v0.2 additions; v0.1 fallback if missing.
    NSString *className = @"MPGOMassSpectrum";
    if ([runGroup hasAttributeNamed:@"spectrum_class"]) {
        className = [runGroup stringAttributeNamed:@"spectrum_class" error:NULL];
        if (className.length == 0) className = @"MPGOMassSpectrum";
    }

    NSString *nucleus = nil;
    double freqMHz = 0.0;
    if ([runGroup hasAttributeNamed:@"nucleus_type"]) {
        nucleus = [runGroup stringAttributeNamed:@"nucleus_type" error:NULL];
        if ([runGroup hasChildNamed:@"_spectrometer_freq_mhz"]) {
            MPGOHDF5Dataset *fd = [runGroup openDatasetNamed:@"_spectrometer_freq_mhz" error:NULL];
            NSData *fdata = [fd readDataWithError:NULL];
            if (fdata.length >= sizeof(double)) {
                freqMHz = ((const double *)fdata.bytes)[0];
            }
        }
    }

    NSMutableArray<MPGOProvenanceRecord *> *provenance = [NSMutableArray array];
    if ([runGroup hasAttributeNamed:@"provenance_json"]) {
        NSString *jstr = [runGroup stringAttributeNamed:@"provenance_json" error:NULL];
        NSData *jdata = [jstr dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *plists = [NSJSONSerialization JSONObjectWithData:jdata
                                                           options:0
                                                             error:NULL];
        for (NSDictionary *p in plists) {
            MPGOProvenanceRecord *r = [MPGOProvenanceRecord fromPlist:p];
            if (r) [provenance addObject:r];
        }
    }

    MPGOHDF5Group *channels = [runGroup openGroupNamed:@"signal_channels" error:error];
    if (!channels) return nil;

    NSArray<NSString *> *channelNames = nil;
    if ([channels hasAttributeNamed:@"channel_names"]) {
        NSString *joined = [channels stringAttributeNamed:@"channel_names" error:NULL];
        channelNames = [joined componentsSeparatedByString:@","];
    } else {
        // v0.1 fallback
        channelNames = @[@"mz", @"intensity"];
    }

    NSMutableDictionary<NSString *, MPGOHDF5Dataset *> *channelDatasets =
        [NSMutableDictionary dictionaryWithCapacity:channelNames.count];
    for (NSString *chName in channelNames) {
        NSString *dsName = [chName stringByAppendingString:@"_values"];
        if (![channels hasChildNamed:dsName]) {
            // Channel is absent — most likely the file is encrypted
            // and this channel lives as `<name>_values_encrypted`. Keep
            // metadata load going; spectrumAtIndex: will error cleanly
            // if anyone later asks for data from this channel.
            continue;
        }
        MPGOHDF5Dataset *ds = [channels openDatasetNamed:dsName error:error];
        if (!ds) return nil;
        channelDatasets[chName] = ds;
    }

    MPGOAcquisitionRun *run = [[self alloc] init];
    run->_acquisitionMode      = mode;
    run->_instrumentConfig     = cfg;
    run->_spectrumIndex        = idx;
    run->_signalChannelsGroup  = channels;
    run->_channelDatasets      = channelDatasets;
    run->_channelNames         = [channelNames copy];
    run->_spectrumClassName    = [className copy];
    run->_nucleusType          = [nucleus copy];
    run->_spectrometerFrequencyMHz = freqMHz;
    run->_inMemorySpectra      = nil;
    run->_streamPosition       = 0;
    run->_provenance           = provenance;
    return run;
}

#pragma mark - Random access

- (id)spectrumAtIndex:(NSUInteger)index error:(NSError **)error
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

    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];

    NSMutableDictionary<NSString *, MPGOSignalArray *> *channels =
        [NSMutableDictionary dictionaryWithCapacity:_channelNames.count];
    for (NSString *chName in _channelNames) {
        MPGOHDF5Dataset *ds = _channelDatasets[chName];
        NSData *d = [ds readDataAtOffset:(NSUInteger)off
                                    count:(NSUInteger)len
                                    error:error];
        if (!d) return nil;
        MPGOSignalArray *sa = [[MPGOSignalArray alloc] initWithBuffer:d
                                                                length:len
                                                              encoding:enc
                                                                  axis:nil];
        channels[chName] = sa;
    }

    if ([_spectrumClassName isEqualToString:@"MPGOMassSpectrum"]) {
        return [[MPGOMassSpectrum alloc]
                initWithMzArray:channels[@"mz"]
                 intensityArray:channels[@"intensity"]
                        msLevel:[_spectrumIndex msLevelAt:index]
                       polarity:[_spectrumIndex polarityAt:index]
                     scanWindow:nil
                  indexPosition:index
                scanTimeSeconds:[_spectrumIndex retentionTimeAt:index]
                    precursorMz:[_spectrumIndex precursorMzAt:index]
                precursorCharge:[_spectrumIndex precursorChargeAt:index]
                          error:error];
    }

    if ([_spectrumClassName isEqualToString:@"MPGONMRSpectrum"]) {
        return [[MPGONMRSpectrum alloc]
                initWithChemicalShiftArray:channels[@"chemical_shift"]
                            intensityArray:channels[@"intensity"]
                               nucleusType:_nucleusType
                  spectrometerFrequencyMHz:_spectrometerFrequencyMHz
                             indexPosition:index
                           scanTimeSeconds:[_spectrumIndex retentionTimeAt:index]
                                     error:error];
    }

    if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
        @"unknown spectrum_class %@ in acquisition run", _spectrumClassName);
    return nil;
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

#pragma mark - Persistence context

- (void)setPersistenceFilePath:(NSString *)path runName:(NSString *)runName
{
    _persistenceFilePath = [path copy];
    _persistenceRunName  = [runName copy];
}

- (void)releaseHDF5Handles
{
    _channelDatasets     = nil;
    _signalChannelsGroup = nil;
}

#pragma mark - MPGOProvenanceable

- (void)addProcessingStep:(MPGOProvenanceRecord *)step
{
    if (!_provenance) _provenance = [NSMutableArray array];
    if (step) [_provenance addObject:step];
}

- (NSArray<MPGOProvenanceRecord *> *)provenanceChain
{
    return _provenance ? [_provenance copy] : @[];
}

- (NSArray<NSString *> *)inputEntities
{
    NSMutableSet *set = [NSMutableSet set];
    for (MPGOProvenanceRecord *r in _provenance) [set addObjectsFromArray:r.inputRefs];
    return [set allObjects];
}

- (NSArray<NSString *> *)outputEntities
{
    NSMutableSet *set = [NSMutableSet set];
    for (MPGOProvenanceRecord *r in _provenance) [set addObjectsFromArray:r.outputRefs];
    return [set allObjects];
}

#pragma mark - MPGOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(MPGOEncryptionLevel)level
                 error:(NSError **)error
{
    (void)level;
    if (!_persistenceFilePath || !_persistenceRunName) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOAcquisitionRun: cannot encrypt in-memory run; persist via "
            @"MPGOSpectralDataset first so the run has a file context");
        return NO;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [MPGOEncryptionManager encryptIntensityChannelInRun:_persistenceRunName
                                                    atFilePath:_persistenceFilePath
                                                       withKey:key
                                                         error:error];
#pragma clang diagnostic pop
}

- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error
{
    if (!_persistenceFilePath || !_persistenceRunName) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOAcquisitionRun: no persistence context for decrypt");
        return NO;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *plain = [MPGOEncryptionManager
                      decryptIntensityChannelInRun:_persistenceRunName
                                        atFilePath:_persistenceFilePath
                                           withKey:key
                                             error:error];
#pragma clang diagnostic pop
    return plain != nil;
}

- (MPGOAccessPolicy *)accessPolicy         { return _accessPolicy; }
- (void)setAccessPolicy:(MPGOAccessPolicy *)policy { _accessPolicy = policy; }

@end
