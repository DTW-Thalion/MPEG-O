#import "MPGOSpectrumIndex.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOIsolationWindow.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "Providers/MPGOStorageProtocols.h"
#import "HDF5/MPGOHDF5Types.h"

@implementation MPGOSpectrumIndex
{
    NSData *_offsets;          // uint64_t[count]
    NSData *_lengths;          // uint32_t[count]
    NSData *_retentionTimes;   // double[count]
    NSData *_msLevels;         // uint32_t[count] — stored as int32 for HDF5
    NSData *_polarities;       // int32_t[count]
    NSData *_precursorMzs;     // double[count]
    NSData *_precursorCharges; // int32_t[count]
    NSData *_basePeakIntensities; // double[count]
    // M74: nil (legacy) or all-four populated.
    NSData *_activationMethods;     // int32_t[count]
    NSData *_isolationTargetMzs;    // double[count]
    NSData *_isolationLowerOffsets; // double[count]
    NSData *_isolationUpperOffsets; // double[count]
    NSUInteger _count;
}

- (instancetype)initWithOffsets:(NSData *)offsets
                        lengths:(NSData *)lengths
                 retentionTimes:(NSData *)retentionTimes
                       msLevels:(NSData *)msLevels
                     polarities:(NSData *)polarities
                   precursorMzs:(NSData *)precursorMzs
               precursorCharges:(NSData *)precursorCharges
             basePeakIntensities:(NSData *)basePeakIntensities
{
    return [self initWithOffsets:offsets
                         lengths:lengths
                  retentionTimes:retentionTimes
                        msLevels:msLevels
                      polarities:polarities
                    precursorMzs:precursorMzs
                precursorCharges:precursorCharges
             basePeakIntensities:basePeakIntensities
               activationMethods:nil
              isolationTargetMzs:nil
           isolationLowerOffsets:nil
           isolationUpperOffsets:nil];
}

- (instancetype)initWithOffsets:(NSData *)offsets
                        lengths:(NSData *)lengths
                 retentionTimes:(NSData *)retentionTimes
                       msLevels:(NSData *)msLevels
                     polarities:(NSData *)polarities
                   precursorMzs:(NSData *)precursorMzs
               precursorCharges:(NSData *)precursorCharges
             basePeakIntensities:(NSData *)basePeakIntensities
               activationMethods:(NSData *)activationMethods
             isolationTargetMzs:(NSData *)isolationTargetMzs
          isolationLowerOffsets:(NSData *)isolationLowerOffsets
          isolationUpperOffsets:(NSData *)isolationUpperOffsets
{
    BOOL anyNil = !activationMethods || !isolationTargetMzs
               || !isolationLowerOffsets || !isolationUpperOffsets;
    BOOL allNil = !activationMethods && !isolationTargetMzs
               && !isolationLowerOffsets && !isolationUpperOffsets;
    NSAssert(allNil || !anyNil,
        @"MPGOSpectrumIndex: M74 columns must be all-nil or all-non-nil");
    self = [super init];
    if (self) {
        _offsets             = [offsets copy];
        _lengths             = [lengths copy];
        _retentionTimes      = [retentionTimes copy];
        _msLevels            = [msLevels copy];
        _polarities          = [polarities copy];
        _precursorMzs        = [precursorMzs copy];
        _precursorCharges    = [precursorCharges copy];
        _basePeakIntensities = [basePeakIntensities copy];
        _activationMethods     = [activationMethods copy];
        _isolationTargetMzs    = [isolationTargetMzs copy];
        _isolationLowerOffsets = [isolationLowerOffsets copy];
        _isolationUpperOffsets = [isolationUpperOffsets copy];
        _count               = offsets.length / sizeof(uint64_t);
    }
    return self;
}

- (NSUInteger)count { return _count; }

- (uint64_t)offsetAt:(NSUInteger)i { return ((const uint64_t *)_offsets.bytes)[i]; }
- (uint32_t)lengthAt:(NSUInteger)i { return ((const uint32_t *)_lengths.bytes)[i]; }
- (double)retentionTimeAt:(NSUInteger)i { return ((const double *)_retentionTimes.bytes)[i]; }
- (uint8_t)msLevelAt:(NSUInteger)i      { return (uint8_t)((const int32_t *)_msLevels.bytes)[i]; }
- (MPGOPolarity)polarityAt:(NSUInteger)i { return (MPGOPolarity)((const int32_t *)_polarities.bytes)[i]; }
- (double)precursorMzAt:(NSUInteger)i   { return ((const double *)_precursorMzs.bytes)[i]; }
- (uint8_t)precursorChargeAt:(NSUInteger)i { return (uint8_t)((const int32_t *)_precursorCharges.bytes)[i]; }
- (double)basePeakIntensityAt:(NSUInteger)i { return ((const double *)_basePeakIntensities.bytes)[i]; }

- (BOOL)hasActivationDetail { return _activationMethods != nil; }

- (MPGOActivationMethod)activationMethodAt:(NSUInteger)i
{
    if (!_activationMethods) return MPGOActivationMethodNone;
    return (MPGOActivationMethod)((const int32_t *)_activationMethods.bytes)[i];
}

- (MPGOIsolationWindow *)isolationWindowAt:(NSUInteger)i
{
    if (!_isolationTargetMzs) return nil;
    double t = ((const double *)_isolationTargetMzs.bytes)[i];
    double lo = ((const double *)_isolationLowerOffsets.bytes)[i];
    double hi = ((const double *)_isolationUpperOffsets.bytes)[i];
    if (t == 0.0 && lo == 0.0 && hi == 0.0) return nil;
    return [MPGOIsolationWindow windowWithTargetMz:t
                                        lowerOffset:lo
                                        upperOffset:hi];
}

- (NSIndexSet *)indicesInRetentionTimeRange:(MPGOValueRange *)range
{
    const double *rts = _retentionTimes.bytes;
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < _count; i++) {
        if ([range containsValue:rts[i]]) [out addIndex:i];
    }
    return out;
}

- (NSIndexSet *)indicesForMsLevel:(uint8_t)msLevel
{
    const int32_t *ml = _msLevels.bytes;
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < _count; i++) {
        if (ml[i] == msLevel) [out addIndex:i];
    }
    return out;
}

#pragma mark - HDF5

static BOOL writeArray(MPGOHDF5Group *g, NSString *name, MPGOPrecision p,
                       NSData *data, NSError **error)
{
    NSUInteger n = data.length / MPGOPrecisionElementSize(p);
    MPGOHDF5Dataset *ds = [g createDatasetNamed:name
                                       precision:p
                                          length:n
                                       chunkSize:4096
                                compressionLevel:6
                                           error:error];
    if (!ds) return NO;
    return [ds writeData:data error:error];
}

static NSData *readArray(MPGOHDF5Group *g, NSString *name, NSError **error)
{
    MPGOHDF5Dataset *ds = [g openDatasetNamed:name error:error];
    if (!ds) return nil;
    return [ds readDataWithError:error];
}

- (BOOL)writeToGroup:(MPGOHDF5Group *)parent error:(NSError **)error
{
    MPGOHDF5Group *g = [parent createGroupNamed:@"spectrum_index" error:error];
    if (!g) return NO;
    if (![g setIntegerAttribute:@"count" value:(int64_t)_count error:error]) return NO;
    if (!writeArray(g, @"offsets",          MPGOPrecisionInt64,   _offsets,          error)) return NO;
    if (!writeArray(g, @"lengths",          MPGOPrecisionUInt32,  _lengths,          error)) return NO;
    if (!writeArray(g, @"retention_times",  MPGOPrecisionFloat64, _retentionTimes,   error)) return NO;
    if (!writeArray(g, @"ms_levels",        MPGOPrecisionInt32,   _msLevels,         error)) return NO;
    if (!writeArray(g, @"polarities",       MPGOPrecisionInt32,   _polarities,       error)) return NO;
    if (!writeArray(g, @"precursor_mzs",    MPGOPrecisionFloat64, _precursorMzs,     error)) return NO;
    if (!writeArray(g, @"precursor_charges", MPGOPrecisionInt32,  _precursorCharges, error)) return NO;
    if (!writeArray(g, @"base_peak_intensities", MPGOPrecisionFloat64, _basePeakIntensities, error)) return NO;
    // M74 schema-gating: emit the four optional columns only when the
    // index was built with them. The designated initializer enforces
    // all-or-nothing, so probing one column is sufficient.
    if (_activationMethods) {
        if (!writeArray(g, @"activation_methods",      MPGOPrecisionInt32,   _activationMethods,     error)) return NO;
        if (!writeArray(g, @"isolation_target_mzs",    MPGOPrecisionFloat64, _isolationTargetMzs,    error)) return NO;
        if (!writeArray(g, @"isolation_lower_offsets", MPGOPrecisionFloat64, _isolationLowerOffsets, error)) return NO;
        if (!writeArray(g, @"isolation_upper_offsets", MPGOPrecisionFloat64, _isolationUpperOffsets, error)) return NO;
    }
    return YES;
}

+ (instancetype)readFromGroup:(MPGOHDF5Group *)parent error:(NSError **)error
{
    MPGOHDF5Group *g = [parent openGroupNamed:@"spectrum_index" error:error];
    if (!g) return nil;
    NSData *offsets = readArray(g, @"offsets", error);
    NSData *lengths = readArray(g, @"lengths", error);
    NSData *rts     = readArray(g, @"retention_times", error);
    NSData *ml      = readArray(g, @"ms_levels", error);
    NSData *pol     = readArray(g, @"polarities", error);
    NSData *pmz     = readArray(g, @"precursor_mzs", error);
    NSData *pc      = readArray(g, @"precursor_charges", error);
    NSData *bp      = readArray(g, @"base_peak_intensities", error);
    if (!offsets || !lengths || !rts || !ml || !pol || !pmz || !pc || !bp) return nil;
    // M74 schema-gating: probe for the four optional columns.
    NSData *am = nil, *itm = nil, *ilo = nil, *iup = nil;
    if ([g hasChildNamed:@"activation_methods"]) {
        am  = readArray(g, @"activation_methods",      error); if (!am)  return nil;
        itm = readArray(g, @"isolation_target_mzs",    error); if (!itm) return nil;
        ilo = readArray(g, @"isolation_lower_offsets", error); if (!ilo) return nil;
        iup = readArray(g, @"isolation_upper_offsets", error); if (!iup) return nil;
    }
    return [[self alloc] initWithOffsets:offsets
                                 lengths:lengths
                          retentionTimes:rts
                                msLevels:ml
                              polarities:pol
                            precursorMzs:pmz
                        precursorCharges:pc
                     basePeakIntensities:bp
                        activationMethods:am
                      isolationTargetMzs:itm
                   isolationLowerOffsets:ilo
                   isolationUpperOffsets:iup];
}

static NSData *readStorageArray(id<MPGOStorageGroup> g, NSString *name, NSError **error)
{
    id<MPGOStorageDataset> ds = [g openDatasetNamed:name error:error];
    if (!ds) return nil;
    id val = [ds readAll:error];
    if ([val isKindOfClass:[NSData class]]) return val;
    return nil;
}

+ (instancetype)readFromStorageGroup:(id)parent error:(NSError **)error
{
    id<MPGOStorageGroup> par = (id<MPGOStorageGroup>)parent;
    if (![par hasChildNamed:@"spectrum_index"]) return nil;
    id<MPGOStorageGroup> g = [par openGroupNamed:@"spectrum_index" error:error];
    if (!g) return nil;
    NSData *offsets = readStorageArray(g, @"offsets", error);
    NSData *lengths = readStorageArray(g, @"lengths", error);
    NSData *rts     = readStorageArray(g, @"retention_times", error);
    NSData *ml      = readStorageArray(g, @"ms_levels", error);
    NSData *pol     = readStorageArray(g, @"polarities", error);
    NSData *pmz     = readStorageArray(g, @"precursor_mzs", error);
    NSData *pc      = readStorageArray(g, @"precursor_charges", error);
    NSData *bp      = readStorageArray(g, @"base_peak_intensities", error);
    if (!offsets || !lengths || !rts || !ml || !pol || !pmz || !pc || !bp) return nil;
    // M74 schema-gating: probe for the four optional columns.
    NSData *am = nil, *itm = nil, *ilo = nil, *iup = nil;
    if ([g hasChildNamed:@"activation_methods"]) {
        am  = readStorageArray(g, @"activation_methods",      error); if (!am)  return nil;
        itm = readStorageArray(g, @"isolation_target_mzs",    error); if (!itm) return nil;
        ilo = readStorageArray(g, @"isolation_lower_offsets", error); if (!ilo) return nil;
        iup = readStorageArray(g, @"isolation_upper_offsets", error); if (!iup) return nil;
    }
    return [[self alloc] initWithOffsets:offsets
                                 lengths:lengths
                          retentionTimes:rts
                                msLevels:ml
                              polarities:pol
                            precursorMzs:pmz
                        precursorCharges:pc
                     basePeakIntensities:bp
                        activationMethods:am
                      isolationTargetMzs:itm
                   isolationLowerOffsets:ilo
                   isolationUpperOffsets:iup];
}

@end
