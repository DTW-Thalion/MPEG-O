#import "TTIOAcquisitionRun.h"
#import "TTIOInstrumentConfig.h"
#import "TTIOSpectrumIndex.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Spectra/TTIONMRSpectrum.h"
#import "Spectra/TTIOChromatogram.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOIsolationWindow.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Dataset/TTIOCompoundIO.h"
#import "Core/TTIONumpress.h"
#import "Protection/TTIOEncryptionManager.h"
#import "Protection/TTIOAccessPolicy.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "HDF5/TTIOHDF5Types.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOHDF5Provider.h"

@implementation TTIOAcquisitionRun
{
    // Phase 1: Run protocol name. Set by readFromGroup:name: /
    // readFromStorageGroup:name: at load time, by
    // setPersistenceFilePath:runName: post-load (kept in sync with
    // _persistenceRunName below), or remains @"" for in-memory runs
    // not yet persisted.
    NSString                    *_name;
    NSArray                     *_inMemorySpectra;       // nil when read-from-disk
    // v0.7 M44: storage-protocol iVars. Populated by
    // +readFromGroup:name:error: via TTIOHDF5Provider's adapter
    // factory; the hot spectrum-read path goes through the protocol
    // (readSliceAtOffset:count:error:) so a future non-HDF5 provider
    // can host a run without per-class migration.
    id<TTIOStorageGroup>         _storageSignalGroup;    // nil when in-memory
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *_storageDatasets;
    NSArray<NSString *>         *_channelNames;          // ordered list
    NSUInteger                   _streamPosition;

    NSMutableArray<TTIOProvenanceRecord *> *_provenance;
    TTIOAccessPolicy            *_accessPolicy;

    // M21: eagerly decoded Numpress-delta channels, keyed by channel
    // name. When a channel is present here, spectrumAtIndex: slices
    // into this float64 buffer instead of reading the HDF5 dataset,
    // because Numpress decoding needs the running sum prefix.
    NSMutableDictionary<NSString *, NSData *> *_numpressChannels;

    // M5-handoff: in-memory plaintext channels populated by
    // -decryptWithKey:error:. Keyed by channel name. When present,
    // spectrumAtIndex: slices into this float64 buffer so spectra are
    // readable through the normal API after decrypt without modifying
    // the on-disk file (mirrors the Python rehydrate-in-memory
    // semantics in TTIOAcquisitionRun).
    NSMutableDictionary<NSString *, NSData *> *_decryptedChannels;

    // Persistence context attached post-load for protocol encryption
    NSString *_persistenceFilePath;
    NSString *_persistenceRunName;

    // M24: chromatogram traces carried with this run.
    NSArray<TTIOChromatogram *> *_chromatograms;
}

@synthesize chromatograms = _chromatograms;
@synthesize name = _name;

#pragma mark - Construction

- (instancetype)initWithSpectra:(NSArray *)spectra
                acquisitionMode:(TTIOAcquisitionMode)mode
               instrumentConfig:(TTIOInstrumentConfig *)config
{
    self = [super init];
    if (self) {
        _name             = @"";
        _inMemorySpectra  = [spectra copy];
        _acquisitionMode  = mode;
        _instrumentConfig = config;
        _streamPosition   = 0;
        _provenance       = [NSMutableArray array];
        _signalCompression = TTIOCompressionZlib;  // M21 default

        if (spectra.count > 0) {
            TTIOSpectrum *first = spectra[0];
            _spectrumClassName = NSStringFromClass([first class]);
            _channelNames = [[first.signalArrays allKeys]
                sortedArrayUsingSelector:@selector(compare:)];

            if ([first isKindOfClass:[TTIONMRSpectrum class]]) {
                TTIONMRSpectrum *n = (TTIONMRSpectrum *)first;
                _nucleusType = [n.nucleusType copy];
                _spectrometerFrequencyMHz = n.spectrometerFrequencyMHz;
            }
        } else {
            _spectrumClassName = @"TTIOMassSpectrum";
            _channelNames = @[@"mz", @"intensity"];
        }

        _spectrumIndex = [self buildIndexFromSpectra:spectra];
        _chromatograms = @[];
        _modality = @"mass_spectrometry";
    }
    return self;
}

- (instancetype)initWithSpectra:(NSArray *)spectra
                  chromatograms:(NSArray<TTIOChromatogram *> *)chromatograms
                acquisitionMode:(TTIOAcquisitionMode)mode
               instrumentConfig:(TTIOInstrumentConfig *)config
{
    self = [self initWithSpectra:spectra acquisitionMode:mode instrumentConfig:config];
    if (self) {
        _chromatograms = chromatograms ? [chromatograms copy] : @[];
    }
    return self;
}

#pragma mark - Index construction

- (TTIOSpectrumIndex *)buildIndexFromSpectra:(NSArray *)spectra
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

    // M74: scan once to see if any MS spectrum carries activation/isolation
    // detail. If so, build four parallel optional columns; otherwise pass nil
    // so the index reflects the legacy (no opt_ms2_activation_detail) layout.
    BOOL anyM74 = NO;
    for (NSUInteger i = 0; i < n; i++) {
        TTIOSpectrum *s = spectra[i];
        if (![s isKindOfClass:[TTIOMassSpectrum class]]) continue;
        TTIOMassSpectrum *ms = (TTIOMassSpectrum *)s;
        if (ms.activationMethod != TTIOActivationMethodNone ||
            ms.isolationWindow != nil) { anyM74 = YES; break; }
    }
    NSMutableData *actM = nil;
    NSMutableData *isoT = nil;
    NSMutableData *isoL = nil;
    NSMutableData *isoU = nil;
    int32_t *actMp = NULL;
    double  *isoTp = NULL;
    double  *isoLp = NULL;
    double  *isoUp = NULL;
    if (anyM74) {
        actM = [NSMutableData dataWithLength:n * sizeof(int32_t)];
        isoT = [NSMutableData dataWithLength:n * sizeof(double)];
        isoL = [NSMutableData dataWithLength:n * sizeof(double)];
        isoU = [NSMutableData dataWithLength:n * sizeof(double)];
        actMp = actM.mutableBytes;
        isoTp = isoT.mutableBytes;
        isoLp = isoL.mutableBytes;
        isoUp = isoU.mutableBytes;
    }

    NSString *firstChannel = _channelNames.firstObject;
    uint64_t cursor = 0;
    for (NSUInteger i = 0; i < n; i++) {
        TTIOSpectrum *s = spectra[i];
        TTIOSignalArray *primary = s.signalArrays[firstChannel];
        off[i] = cursor;
        len[i] = (uint32_t)primary.length;
        rt[i]  = s.scanTimeSeconds;
        pmp[i] = s.precursorMz;
        pcp[i] = (int32_t)s.precursorCharge;

        if ([s isKindOfClass:[TTIOMassSpectrum class]]) {
            TTIOMassSpectrum *ms = (TTIOMassSpectrum *)s;
            mlp[i] = (int32_t)ms.msLevel;
            plp[i] = (int32_t)ms.polarity;

            double maxI = 0;
            TTIOSignalArray *inA = ms.intensityArray;
            const double *intP = inA.buffer.bytes;
            NSUInteger m = inA.length;
            for (NSUInteger j = 0; j < m; j++) if (intP[j] > maxI) maxI = intP[j];
            bpp[i] = maxI;

            if (anyM74) {
                actMp[i] = (int32_t)ms.activationMethod;
                TTIOIsolationWindow *iw = ms.isolationWindow;
                if (iw) {
                    isoTp[i] = iw.targetMz;
                    isoLp[i] = iw.lowerOffset;
                    isoUp[i] = iw.upperOffset;
                } else {
                    isoTp[i] = 0.0;
                    isoLp[i] = 0.0;
                    isoUp[i] = 0.0;
                }
            }
        } else {
            // NMR or other non-MS spectra: sentinel values.
            mlp[i] = 0;
            plp[i] = (int32_t)TTIOPolarityUnknown;

            double maxI = 0;
            TTIOSignalArray *inA = s.signalArrays[@"intensity"];
            if (inA) {
                const double *intP = inA.buffer.bytes;
                NSUInteger m = inA.length;
                for (NSUInteger j = 0; j < m; j++) if (intP[j] > maxI) maxI = intP[j];
            }
            bpp[i] = maxI;

            if (anyM74) {
                actMp[i] = (int32_t)TTIOActivationMethodNone;
                isoTp[i] = 0.0;
                isoLp[i] = 0.0;
                isoUp[i] = 0.0;
            }
        }

        cursor += primary.length;
    }
    return [[TTIOSpectrumIndex alloc] initWithOffsets:offsets
                                              lengths:lengths
                                       retentionTimes:rts
                                             msLevels:ml
                                           polarities:pol
                                         precursorMzs:pmz
                                     precursorCharges:pc
                                  basePeakIntensities:bp
                                    activationMethods:actM
                                   isolationTargetMzs:isoT
                                isolationLowerOffsets:isoL
                                isolationUpperOffsets:isoU];
}

#pragma mark - HDF5 write

- (BOOL)writeToGroup:(TTIOHDF5Group *)parent name:(NSString *)name error:(NSError **)error
{
    NSParameterAssert(_inMemorySpectra != nil);  // disk-backed runs are read-only

    TTIOHDF5Group *runGroup = [parent createGroupNamed:name error:error];
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
        TTIOHDF5Dataset *fd = [runGroup createDatasetNamed:@"_spectrometer_freq_mhz"
                                                 precision:TTIOPrecisionFloat64
                                                    length:1
                                                 chunkSize:0
                                          compressionLevel:0
                                                     error:error];
        if (!fd) return NO;
        double f[1] = { _spectrometerFrequencyMHz };
        if (![fd writeData:[NSData dataWithBytes:f length:sizeof(f)] error:error]) return NO;
    }

    // Per-run provenance.
    //
    // v0.3 writes the records as a compound HDF5 dataset at
    //     /study/ms_runs/<run>/provenance/steps
    // using the same compound type as the dataset-level `/study/provenance`
    // (see TTIOCompoundIO). The `compound_per_run_provenance` feature flag
    // on the root group advertises this layout.
    //
    // For backward compatibility with v0.2 readers (including the in-tree
    // signature manager which still operates on the JSON blob), the writer
    // keeps `@provenance_json` as a legacy mirror. M18 will replace the
    // mirror with a canonical-byte-order signature path that covers the
    // compound dataset directly; until then the mirror is intentional.
    if (_provenance.count > 0) {
        TTIOHDF5Group *provGroup =
            [runGroup createGroupNamed:@"provenance" error:error];
        if (!provGroup) return NO;
        if (![TTIOCompoundIO writeProvenance:_provenance
                                   intoGroup:provGroup
                                datasetNamed:@"steps"
                                       error:error]) return NO;

        NSMutableArray *plists = [NSMutableArray arrayWithCapacity:_provenance.count];
        for (TTIOProvenanceRecord *r in _provenance) [plists addObject:[r asPlist]];
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

    TTIOHDF5Group *channels = [runGroup createGroupNamed:@"signal_channels" error:error];
    if (!channels) return NO;

    NSString *namesJoined = [_channelNames componentsJoinedByString:@","];
    if (![channels setStringAttribute:@"channel_names"
                                value:namesJoined error:error]) return NO;

    NSUInteger total = 0;
    for (TTIOSpectrum *s in _inMemorySpectra) {
        total += [s.signalArrays[_channelNames.firstObject] length];
    }

    for (NSString *chName in _channelNames) {
        // Concat per-spectrum channel buffers into one flat NSData.
        // NSMutableData would zero-fill the backing store on
        // -dataWithLength: before we memcpy over it; allocate a bare
        // C buffer instead and hand it to NSData via -dataWithBytesNoCopy:
        // so the compressor sees a single contiguous region without the
        // zero-fill / NSMutableData bookkeeping tax. ~3× faster concat
        // on 100K-spectrum runs.
        NSUInteger totalBytes = total * sizeof(double);
        void *raw = malloc(totalBytes);
        if (!raw) {
            if (error) *error = TTIOMakeError(TTIOErrorDatasetCreate,
                @"out of memory concatenating signal channel '%@'", chName);
            return NO;
        }
        NSUInteger cursor = 0;
        for (TTIOSpectrum *s in _inMemorySpectra) {
            TTIOSignalArray *arr = s.signalArrays[chName];
            NSUInteger n = arr.length;
            memcpy((uint8_t *)raw + cursor * sizeof(double),
                   arr.buffer.bytes, n * sizeof(double));
            cursor += n;
        }
        NSData *all = [NSData dataWithBytesNoCopy:raw length:totalBytes freeWhenDone:YES];
        NSString *dsName = [chName stringByAppendingString:@"_values"];

        if (_signalCompression == TTIOCompressionNumpressDelta) {
            // Fixed-point + first-difference transform. The dataset
            // stores int64 deltas; the reader detects the
            // ``@numpress_fixed_point`` attribute and reverses.
            const double *src = (const double *)all.bytes;
            double minV = src[0], maxV = src[0];
            for (NSUInteger k = 1; k < total; k++) {
                if (src[k] < minV) minV = src[k];
                if (src[k] > maxV) maxV = src[k];
            }
            int64_t scale = [TTIONumpress scaleForValueRangeMin:minV max:maxV];
            NSMutableData *deltas = [NSMutableData dataWithLength:total * sizeof(int64_t)];
            if (![TTIONumpress encodeFloat64:src
                                        count:total
                                        scale:scale
                                    outDeltas:(int64_t *)deltas.mutableBytes]) {
                if (error) *error = TTIOMakeError(TTIOErrorDatasetCreate,
                    @"numpress encode failed for '%@'", dsName);
                return NO;
            }
            TTIOHDF5Dataset *ds =
                [channels createDatasetNamed:dsName
                                   precision:TTIOPrecisionInt64
                                      length:total
                                   chunkSize:65536
                                 compression:TTIOCompressionZlib
                            compressionLevel:6
                                       error:error];
            if (!ds) return NO;
            if (![ds writeData:deltas error:error]) return NO;
            if (![channels setIntegerAttribute:
                    [NSString stringWithFormat:@"%@_numpress_fixed_point", chName]
                                         value:scale
                                         error:error]) return NO;
        } else {
            TTIOHDF5Dataset *ds =
                [channels createDatasetNamed:dsName
                                   precision:TTIOPrecisionFloat64
                                      length:total
                                   chunkSize:65536
                                 compression:_signalCompression
                            compressionLevel:6
                                       error:error];
            if (!ds) return NO;
            if (![ds writeData:all error:error]) return NO;
        }
    }

    // M24: chromatograms under <run>/chromatograms/
    if (_chromatograms.count > 0) {
        if (![self writeChromatogramsToRunGroup:runGroup error:error]) return NO;
    }

    return YES;
}

// M24 helper — lays out /chromatograms/ with concatenated time/intensity
// datasets and a chromatogram_index/ subgroup of parallel metadata.
- (BOOL)writeChromatogramsToRunGroup:(TTIOHDF5Group *)runGroup
                                error:(NSError **)error
{
    NSUInteger nChroms = _chromatograms.count;
    TTIOHDF5Group *chromGroup =
        [runGroup createGroupNamed:@"chromatograms" error:error];
    if (!chromGroup) return NO;
    if (![chromGroup setIntegerAttribute:@"count"
                                    value:(int64_t)nChroms
                                    error:error]) return NO;

    NSUInteger totalPoints = 0;
    for (TTIOChromatogram *c in _chromatograms) totalPoints += c.timeArray.length;

    NSMutableData *timeAll = [NSMutableData dataWithLength:totalPoints * sizeof(double)];
    NSMutableData *intAll  = [NSMutableData dataWithLength:totalPoints * sizeof(double)];

    int64_t  *offsets      = calloc(nChroms, sizeof(int64_t));
    uint32_t *lengths      = calloc(nChroms, sizeof(uint32_t));
    int32_t  *types        = calloc(nChroms, sizeof(int32_t));
    double   *targetMzs    = calloc(nChroms, sizeof(double));
    double   *precursorMzs = calloc(nChroms, sizeof(double));
    double   *productMzs   = calloc(nChroms, sizeof(double));

    NSUInteger cursor = 0;
    for (NSUInteger i = 0; i < nChroms; i++) {
        TTIOChromatogram *c = _chromatograms[i];
        NSUInteger n = c.timeArray.length;
        memcpy((uint8_t *)timeAll.mutableBytes + cursor * sizeof(double),
               c.timeArray.buffer.bytes, n * sizeof(double));
        memcpy((uint8_t *)intAll.mutableBytes + cursor * sizeof(double),
               c.intensityArray.buffer.bytes, n * sizeof(double));
        offsets[i]      = (int64_t)cursor;
        lengths[i]      = (uint32_t)n;
        types[i]        = (int32_t)c.type;
        targetMzs[i]    = c.targetMz;
        precursorMzs[i] = c.precursorProductMz;
        productMzs[i]   = c.productMz;
        cursor += n;
    }

    BOOL ok = YES;

    #define WRITE_DS(_grp, _dname, _prec, _nelem, _data) do { \
        TTIOHDF5Dataset *_ds = [(_grp) createDatasetNamed:(_dname) \
                                                precision:(_prec) \
                                                   length:(_nelem) \
                                                chunkSize:0 \
                                         compressionLevel:0 \
                                                    error:error]; \
        if (!_ds) { ok = NO; break; } \
        if (![_ds writeData:(_data) error:error]) { ok = NO; break; } \
    } while (0)

    do {
        WRITE_DS(chromGroup, @"time_values",      TTIOPrecisionFloat64, totalPoints, timeAll);
        WRITE_DS(chromGroup, @"intensity_values", TTIOPrecisionFloat64, totalPoints, intAll);

        TTIOHDF5Group *idx =
            [chromGroup createGroupNamed:@"chromatogram_index" error:error];
        if (!idx) { ok = NO; break; }

        WRITE_DS(idx, @"offsets",      TTIOPrecisionInt64,   nChroms,
                 [NSData dataWithBytesNoCopy:offsets      length:nChroms*sizeof(int64_t)  freeWhenDone:NO]);
        WRITE_DS(idx, @"lengths",      TTIOPrecisionUInt32,  nChroms,
                 [NSData dataWithBytesNoCopy:lengths      length:nChroms*sizeof(uint32_t) freeWhenDone:NO]);
        WRITE_DS(idx, @"types",        TTIOPrecisionInt32,   nChroms,
                 [NSData dataWithBytesNoCopy:types        length:nChroms*sizeof(int32_t)  freeWhenDone:NO]);
        WRITE_DS(idx, @"target_mzs",   TTIOPrecisionFloat64, nChroms,
                 [NSData dataWithBytesNoCopy:targetMzs    length:nChroms*sizeof(double)   freeWhenDone:NO]);
        WRITE_DS(idx, @"precursor_mzs",TTIOPrecisionFloat64, nChroms,
                 [NSData dataWithBytesNoCopy:precursorMzs length:nChroms*sizeof(double)   freeWhenDone:NO]);
        WRITE_DS(idx, @"product_mzs",  TTIOPrecisionFloat64, nChroms,
                 [NSData dataWithBytesNoCopy:productMzs   length:nChroms*sizeof(double)   freeWhenDone:NO]);
    } while (0);

    #undef WRITE_DS

    free(offsets); free(lengths); free(types);
    free(targetMzs); free(precursorMzs); free(productMzs);
    return ok;
}

#pragma mark - HDF5 read

+ (instancetype)readFromStorageGroup:(id)parent
                                 name:(NSString *)name
                                error:(NSError **)error
{
    id<TTIOStorageGroup> par = (id<TTIOStorageGroup>)parent;
    if (![par hasChildNamed:name]) return nil;
    id<TTIOStorageGroup> runGroup = [par openGroupNamed:name error:error];
    if (!runGroup) return nil;

    id modeObj = [runGroup attributeValueForName:@"acquisition_mode" error:NULL];
    TTIOAcquisitionMode mode = (TTIOAcquisitionMode)
        ([modeObj respondsToSelector:@selector(longLongValue)]
            ? [modeObj longLongValue] : 0);
    id classObj = [runGroup attributeValueForName:@"spectrum_class" error:NULL];
    NSString *className = [classObj isKindOfClass:[NSString class]]
        ? (NSString *)classObj : @"TTIOMassSpectrum";
    id nucObj = [runGroup attributeValueForName:@"nucleus_type" error:NULL];
    NSString *nucleus = [nucObj isKindOfClass:[NSString class]] ? nucObj : nil;
    // v0.11 M79: @modality fallback to "mass_spectrometry" so pre-v0.11
    // runs read back as mass-spec.
    id modObj = [runGroup attributeValueForName:@"modality" error:NULL];
    NSString *modality = ([modObj isKindOfClass:[NSString class]]
                          && [(NSString *)modObj length] > 0)
        ? (NSString *)modObj : @"mass_spectrometry";

    TTIOSpectrumIndex *idx = [TTIOSpectrumIndex readFromStorageGroup:runGroup error:error];
    if (!idx) return nil;

    // signal_channels: read channel_names attr; full signal read is
    // deferred to HDF5-only paths for v0.9.
    NSArray<NSString *> *channelNames = @[];
    if ([runGroup hasChildNamed:@"signal_channels"]) {
        id<TTIOStorageGroup> sc = [runGroup openGroupNamed:@"signal_channels" error:NULL];
        id names = [sc attributeValueForName:@"channel_names" error:NULL];
        if ([names isKindOfClass:[NSString class]]) {
            channelNames = [(NSString *)names componentsSeparatedByString:@","];
        }
    }

    // Provenance via the JSON mirror (compound-dataset decode is HDF5-only).
    NSMutableArray<TTIOProvenanceRecord *> *provenance = [NSMutableArray array];
    id provObj = [runGroup attributeValueForName:@"provenance_json" error:NULL];
    if ([provObj isKindOfClass:[NSString class]] && [(NSString *)provObj length] > 0) {
        NSData *jdata = [(NSString *)provObj dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *plists = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:NULL];
        for (NSDictionary *p in plists) {
            TTIOProvenanceRecord *r = [TTIOProvenanceRecord fromPlist:p];
            if (r) [provenance addObject:r];
        }
    }

    // Default InstrumentConfig; non-HDF5 writers don't persist it today.
    TTIOInstrumentConfig *cfg = [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                                             model:@""
                                                                      serialNumber:@""
                                                                        sourceType:@""
                                                                      analyzerType:@""
                                                                      detectorType:@""];

    TTIOAcquisitionRun *run = [[self alloc] init];
    run->_name                 = [name copy] ?: @"";
    run->_acquisitionMode      = mode;
    run->_instrumentConfig     = cfg;
    run->_spectrumIndex        = idx;
    run->_storageSignalGroup   = nil;
    run->_storageDatasets      = nil;
    run->_channelNames         = [channelNames copy];
    run->_spectrumClassName    = [className copy];
    run->_nucleusType          = [nucleus copy];
    run->_spectrometerFrequencyMHz = 0.0;
    run->_inMemorySpectra      = nil;
    run->_streamPosition       = 0;
    run->_provenance           = provenance;
    run->_numpressChannels     = nil;
    run->_signalCompression    = TTIOCompressionNone;
    run->_chromatograms        = @[];
    run->_modality             = [modality copy];
    return run;
}

+ (instancetype)readFromGroup:(TTIOHDF5Group *)parent name:(NSString *)name error:(NSError **)error
{
    TTIOHDF5Group *runGroup = [parent openGroupNamed:name error:error];
    if (!runGroup) return nil;

    BOOL exists = NO;
    TTIOAcquisitionMode mode =
        (TTIOAcquisitionMode)[runGroup integerAttributeNamed:@"acquisition_mode"
                                                       exists:&exists error:error];

    TTIOInstrumentConfig *cfg = [TTIOInstrumentConfig readFromGroup:runGroup error:error];
    if (!cfg) return nil;

    TTIOSpectrumIndex *idx = [TTIOSpectrumIndex readFromGroup:runGroup error:error];
    if (!idx) return nil;

    // v0.2 additions; v0.1 fallback if missing.
    NSString *className = @"TTIOMassSpectrum";
    if ([runGroup hasAttributeNamed:@"spectrum_class"]) {
        className = [runGroup stringAttributeNamed:@"spectrum_class" error:NULL];
        if (className.length == 0) className = @"TTIOMassSpectrum";
    }

    // v0.11 M79: @modality with pre-v0.11 mass-spec fallback.
    NSString *modality = @"mass_spectrometry";
    if ([runGroup hasAttributeNamed:@"modality"]) {
        NSString *m = [runGroup stringAttributeNamed:@"modality" error:NULL];
        if (m.length > 0) modality = m;
    }

    NSString *nucleus = nil;
    double freqMHz = 0.0;
    if ([runGroup hasAttributeNamed:@"nucleus_type"]) {
        nucleus = [runGroup stringAttributeNamed:@"nucleus_type" error:NULL];
        if ([runGroup hasChildNamed:@"_spectrometer_freq_mhz"]) {
            TTIOHDF5Dataset *fd = [runGroup openDatasetNamed:@"_spectrometer_freq_mhz" error:NULL];
            NSData *fdata = [fd readDataWithError:NULL];
            if (fdata.length >= sizeof(double)) {
                freqMHz = ((const double *)fdata.bytes)[0];
            }
        }
    }

    // Per-run provenance: prefer the v0.3 compound layout at
    // runGroup/provenance/steps; fall back to the v0.2 @provenance_json
    // attribute if the compound subgroup is absent. Pre-v0.2 files had
    // neither form, in which case `provenance` remains an empty array.
    NSMutableArray<TTIOProvenanceRecord *> *provenance = [NSMutableArray array];
    if ([runGroup hasChildNamed:@"provenance"]) {
        TTIOHDF5Group *provGroup = [runGroup openGroupNamed:@"provenance" error:NULL];
        if (provGroup && [provGroup hasChildNamed:@"steps"]) {
            NSArray *compound =
                [TTIOCompoundIO readProvenanceFromGroup:provGroup
                                           datasetNamed:@"steps"
                                                  error:NULL];
            if (compound) [provenance addObjectsFromArray:compound];
        }
    }
    if (provenance.count == 0 && [runGroup hasAttributeNamed:@"provenance_json"]) {
        NSString *jstr = [runGroup stringAttributeNamed:@"provenance_json" error:NULL];
        NSData *jdata = [jstr dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *plists = [NSJSONSerialization JSONObjectWithData:jdata
                                                           options:0
                                                             error:NULL];
        for (NSDictionary *p in plists) {
            TTIOProvenanceRecord *r = [TTIOProvenanceRecord fromPlist:p];
            if (r) [provenance addObject:r];
        }
    }

    TTIOHDF5Group *channels = [runGroup openGroupNamed:@"signal_channels" error:error];
    if (!channels) return nil;

    NSArray<NSString *> *channelNames = nil;
    if ([channels hasAttributeNamed:@"channel_names"]) {
        NSString *joined = [channels stringAttributeNamed:@"channel_names" error:NULL];
        channelNames = [joined componentsSeparatedByString:@","];
    } else {
        // v0.1 fallback
        channelNames = @[@"mz", @"intensity"];
    }

    // v0.7 M44: channelDatasets is a protocol-valued dictionary so
    // the hot-path read routes through TTIOStorageDataset. Each
    // TTIOHDF5Dataset is wrapped via +[TTIOHDF5Provider adapterForDataset:name:]
    // before being stored.
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *channelDatasets =
        [NSMutableDictionary dictionaryWithCapacity:channelNames.count];
    NSMutableDictionary<NSString *, NSData *> *numpressChannels =
        [NSMutableDictionary dictionary];
    TTIOCompression runCompression = TTIOCompressionZlib;
    for (NSString *chName in channelNames) {
        NSString *dsName = [chName stringByAppendingString:@"_values"];
        if (![channels hasChildNamed:dsName]) {
            // Channel is absent — most likely the file is encrypted
            // and this channel lives as `<name>_values_encrypted`. Keep
            // metadata load going; spectrumAtIndex: will error cleanly
            // if anyone later asks for data from this channel.
            continue;
        }

        // M21: detect Numpress-delta encoding via the per-channel
        // ``@<chName>_numpress_fixed_point`` attribute. If present,
        // open the dataset as int64, decode via TTIONumpress, cache
        // the float64 result, and record the codec choice on the run
        // so writers that re-persist this dataset preserve it.
        NSString *scaleAttr = [NSString stringWithFormat:@"%@_numpress_fixed_point", chName];
        if ([channels hasAttributeNamed:scaleAttr]) {
            BOOL exists = NO;
            int64_t scale =
                [channels integerAttributeNamed:scaleAttr exists:&exists error:NULL];
            TTIOHDF5Dataset *ds =
                [channels openDatasetNamed:dsName error:error];
            if (!ds) return nil;
            NSData *raw = [ds readDataWithError:error];
            if (!raw) return nil;
            NSUInteger nElems = raw.length / sizeof(int64_t);
            NSMutableData *decoded =
                [NSMutableData dataWithLength:nElems * sizeof(double)];
            if (![TTIONumpress decodeInt64:(const int64_t *)raw.bytes
                                       count:nElems
                                       scale:scale
                                  outValues:(double *)decoded.mutableBytes]) {
                if (error) *error = TTIOMakeError(TTIOErrorDatasetOpen,
                    @"numpress decode failed for '%@'", chName);
                return nil;
            }
            numpressChannels[chName] = decoded;
            runCompression = TTIOCompressionNumpressDelta;
            continue;
        }

        TTIOHDF5Dataset *ds = [channels openDatasetNamed:dsName error:error];
        if (!ds) return nil;
        channelDatasets[chName] =
            [TTIOHDF5Provider adapterForDataset:ds name:dsName];
    }

    TTIOAcquisitionRun *run = [[self alloc] init];
    run->_name                 = [name copy] ?: @"";
    run->_acquisitionMode      = mode;
    run->_instrumentConfig     = cfg;
    run->_spectrumIndex        = idx;
    run->_storageSignalGroup   = [TTIOHDF5Provider adapterForGroup:channels];
    run->_storageDatasets      = channelDatasets;
    run->_channelNames         = [channelNames copy];
    run->_spectrumClassName    = [className copy];
    run->_nucleusType          = [nucleus copy];
    run->_spectrometerFrequencyMHz = freqMHz;
    run->_modality             = [modality copy];
    run->_inMemorySpectra      = nil;
    run->_streamPosition       = 0;
    run->_provenance           = provenance;
    run->_numpressChannels     = numpressChannels.count > 0 ? numpressChannels : nil;
    run->_signalCompression    = runCompression;

    // M24: read chromatograms if present. Absence means v0.3 file → empty list.
    run->_chromatograms = [self readChromatogramsFromRunGroup:runGroup];
    return run;
}

+ (NSArray<TTIOChromatogram *> *)readChromatogramsFromRunGroup:(TTIOHDF5Group *)runGroup
{
    if (![runGroup hasChildNamed:@"chromatograms"]) return @[];
    TTIOHDF5Group *chromGroup = [runGroup openGroupNamed:@"chromatograms" error:NULL];
    if (!chromGroup) return @[];

    BOOL exists = NO;
    int64_t count = [chromGroup integerAttributeNamed:@"count" exists:&exists error:NULL];
    if (!exists || count <= 0) return @[];

    TTIOHDF5Dataset *timeDs = [chromGroup openDatasetNamed:@"time_values" error:NULL];
    TTIOHDF5Dataset *intDs  = [chromGroup openDatasetNamed:@"intensity_values" error:NULL];
    if (!timeDs || !intDs) return @[];
    NSData *timeAll = [timeDs readDataWithError:NULL];
    NSData *intAll  = [intDs  readDataWithError:NULL];
    if (!timeAll || !intAll) return @[];

    TTIOHDF5Group *idxGroup = [chromGroup openGroupNamed:@"chromatogram_index" error:NULL];
    if (!idxGroup) return @[];

    NSData *offsetsData   = [[idxGroup openDatasetNamed:@"offsets" error:NULL] readDataWithError:NULL];
    NSData *lengthsData   = [[idxGroup openDatasetNamed:@"lengths" error:NULL] readDataWithError:NULL];
    NSData *typesData     = [[idxGroup openDatasetNamed:@"types" error:NULL] readDataWithError:NULL];
    NSData *targetData    = [[idxGroup openDatasetNamed:@"target_mzs" error:NULL] readDataWithError:NULL];
    NSData *precursorData = [[idxGroup openDatasetNamed:@"precursor_mzs" error:NULL] readDataWithError:NULL];
    NSData *productData   = [[idxGroup openDatasetNamed:@"product_mzs" error:NULL] readDataWithError:NULL];
    if (!offsetsData || !lengthsData || !typesData ||
        !targetData || !precursorData || !productData) return @[];

    const int64_t  *offsets      = offsetsData.bytes;
    const uint32_t *lengths      = lengthsData.bytes;
    const int32_t  *types        = typesData.bytes;
    const double   *targetMzs    = targetData.bytes;
    const double   *precursorMzs = precursorData.bytes;
    const double   *productMzs   = productData.bytes;

    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];

    NSMutableArray<TTIOChromatogram *> *out =
        [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int64_t i = 0; i < count; i++) {
        NSUInteger off = (NSUInteger)offsets[i];
        NSUInteger len = (NSUInteger)lengths[i];
        NSData *tSlice = [NSData dataWithBytes:(const uint8_t *)timeAll.bytes + off*sizeof(double)
                                         length:len*sizeof(double)];
        NSData *iSlice = [NSData dataWithBytes:(const uint8_t *)intAll.bytes  + off*sizeof(double)
                                         length:len*sizeof(double)];
        TTIOSignalArray *tArr = [[TTIOSignalArray alloc] initWithBuffer:tSlice
                                                                  length:len
                                                                encoding:enc
                                                                    axis:nil];
        TTIOSignalArray *iArr = [[TTIOSignalArray alloc] initWithBuffer:iSlice
                                                                  length:len
                                                                encoding:enc
                                                                    axis:nil];
        TTIOChromatogram *c =
            [[TTIOChromatogram alloc] initWithTimeArray:tArr
                                          intensityArray:iArr
                                                    type:(TTIOChromatogramType)types[i]
                                                targetMz:targetMzs[i]
                                             precursorMz:precursorMzs[i]
                                               productMz:productMzs[i]
                                                   error:NULL];
        if (c) [out addObject:c];
    }
    return [out copy];
}

#pragma mark - Random access

- (id)spectrumAtIndex:(NSUInteger)index error:(NSError **)error
{
    if (_inMemorySpectra) {
        if (index >= _inMemorySpectra.count) {
            if (error) *error = TTIOMakeError(TTIOErrorOutOfRange,
                @"index %lu beyond spectrum count %lu",
                (unsigned long)index, (unsigned long)_inMemorySpectra.count);
            return nil;
        }
        return _inMemorySpectra[index];
    }

    if (index >= _spectrumIndex.count) {
        if (error) *error = TTIOMakeError(TTIOErrorOutOfRange,
            @"index %lu beyond spectrum count %lu",
            (unsigned long)index, (unsigned long)_spectrumIndex.count);
        return nil;
    }

    uint64_t off = [_spectrumIndex offsetAt:index];
    uint32_t len = [_spectrumIndex lengthAt:index];

    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];

    NSMutableDictionary<NSString *, TTIOSignalArray *> *channels =
        [NSMutableDictionary dictionaryWithCapacity:_channelNames.count];
    for (NSString *chName in _channelNames) {
        NSData *d = nil;
        NSData *plaintext = _decryptedChannels[chName];
        NSData *decoded = plaintext ?: _numpressChannels[chName];
        if (decoded) {
            // Unified element-wise slice: M21 Numpress-delta or
            // M5-handoff decrypted-channels (both are contiguous
            // float64 buffers keyed by off/len in element units).
            const uint8_t *base = (const uint8_t *)decoded.bytes;
            d = [NSData dataWithBytes:base + (NSUInteger)off * sizeof(double)
                               length:(NSUInteger)len * sizeof(double)];
        } else {
            // v0.7 M44: route the hot spectrum read through the
            // storage protocol instead of TTIOHDF5Dataset directly.
            // Works uniformly across HDF5/Memory/SQLite backends;
            // M43's cross-backend byte-identity tests guarantee
            // equivalence.
            id<TTIOStorageDataset> ds = _storageDatasets[chName];
            d = [ds readSliceAtOffset:(NSUInteger)off
                                 count:(NSUInteger)len
                                 error:error];
        }
        if (!d) return nil;
        TTIOSignalArray *sa = [[TTIOSignalArray alloc] initWithBuffer:d
                                                                length:len
                                                              encoding:enc
                                                                  axis:nil];
        channels[chName] = sa;
    }

    if ([_spectrumClassName isEqualToString:@"TTIOMassSpectrum"]) {
        return [[TTIOMassSpectrum alloc]
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

    if ([_spectrumClassName isEqualToString:@"TTIONMRSpectrum"]) {
        return [[TTIONMRSpectrum alloc]
                initWithChemicalShiftArray:channels[@"chemical_shift"]
                            intensityArray:channels[@"intensity"]
                               nucleusType:_nucleusType
                  spectrometerFrequencyMHz:_spectrometerFrequencyMHz
                             indexPosition:index
                           scanTimeSeconds:[_spectrumIndex retentionTimeAt:index]
                                     error:error];
    }

    if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
        @"unknown spectrum_class %@ in acquisition run", _spectrumClassName);
    return nil;
}

- (NSArray<NSNumber *> *)indicesInRetentionTimeRange:(TTIOValueRange *)range
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

#pragma mark - TTIOIndexable

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

#pragma mark - TTIOStreamable

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
    // Phase 1: keep the public Run-protocol name in sync with the
    // persistence-context run name when the latter is supplied.
    if (runName.length > 0) {
        _name = [runName copy];
    }
}

- (void)releaseHDF5Handles
{
    _storageDatasets     = nil;
    _storageSignalGroup  = nil;
}

#pragma mark - TTIOProvenanceable

- (void)addProcessingStep:(TTIOProvenanceRecord *)step
{
    if (!_provenance) _provenance = [NSMutableArray array];
    if (step) [_provenance addObject:step];
}

- (NSArray<TTIOProvenanceRecord *> *)provenanceChain
{
    return _provenance ? [_provenance copy] : @[];
}

- (NSArray<NSString *> *)inputEntities
{
    NSMutableSet *set = [NSMutableSet set];
    for (TTIOProvenanceRecord *r in _provenance) [set addObjectsFromArray:r.inputRefs];
    return [set allObjects];
}

- (NSArray<NSString *> *)outputEntities
{
    NSMutableSet *set = [NSMutableSet set];
    for (TTIOProvenanceRecord *r in _provenance) [set addObjectsFromArray:r.outputRefs];
    return [set allObjects];
}

#pragma mark - TTIOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(TTIOEncryptionLevel)level
                 error:(NSError **)error
{
    (void)level;
    if (!_persistenceFilePath || !_persistenceRunName) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOAcquisitionRun: cannot encrypt in-memory run; persist via "
            @"TTIOSpectralDataset first so the run has a file context");
        return NO;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [TTIOEncryptionManager encryptIntensityChannelInRun:_persistenceRunName
                                                    atFilePath:_persistenceFilePath
                                                       withKey:key
                                                         error:error];
#pragma clang diagnostic pop
}

- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error
{
    if (!_persistenceFilePath || !_persistenceRunName) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOAcquisitionRun: no persistence context for decrypt");
        return NO;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *plain = [TTIOEncryptionManager
                      decryptIntensityChannelInRun:_persistenceRunName
                                        atFilePath:_persistenceFilePath
                                           withKey:key
                                             error:error];
#pragma clang diagnostic pop
    if (!plain) return NO;

    // M5-handoff: cache the concatenated plaintext so
    // -spectrumAtIndex: can slice it directly. The on-disk file stays
    // encrypted — only the open handle sees plaintext.
    if (!_decryptedChannels) {
        _decryptedChannels = [NSMutableDictionary dictionary];
    }
    _decryptedChannels[@"intensity"] = plain;
    return YES;
}

/** Expose the decrypted plaintext for channel ``chName`` if
 *  -decryptWithKey:error: has populated the cache. Returns nil
 *  otherwise. Consumed by TTIOSpectralDataset so the dataset-level
 *  -decryptWithKey:error: can return a {runName: plaintext} NSDictionary
 *  matching the Python surface. Internal API. */
- (NSData *)decryptedChannelNamed:(NSString *)chName
{
    return _decryptedChannels[chName];
}

/** Reattach storage handles after a dataset-level decrypt that had to
 *  close the file for compound-dataset unsealing. Accepts the fresh
 *  signal_channels ``TTIOHDF5Group`` from the reopened file and
 *  rebuilds ``_storageSignalGroup`` / ``_storageDatasets`` so
 *  ``spectrumAtIndex:`` can once again read unencrypted channels
 *  (mz, chemical_shift, ...) from disk. The decrypted intensity
 *  channel continues to serve from the in-memory cache. Internal API
 *  — called only by TTIOSpectralDataset. */
- (BOOL)reattachSignalHandlesFromGroup:(TTIOHDF5Group *)channels error:(NSError **)error
{
    if (!channels) return NO;
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *datasets =
        [NSMutableDictionary dictionaryWithCapacity:_channelNames.count];
    for (NSString *chName in _channelNames) {
        NSString *dsName = [chName stringByAppendingString:@"_values"];
        if (![channels hasChildNamed:dsName]) continue;  // encrypted / absent
        TTIOHDF5Dataset *ds = [channels openDatasetNamed:dsName error:error];
        if (!ds) return NO;
        datasets[chName] = [TTIOHDF5Provider adapterForDataset:ds name:dsName];
    }
    _storageSignalGroup = [TTIOHDF5Provider adapterForGroup:channels];
    _storageDatasets    = datasets;
    return YES;
}

- (TTIOAccessPolicy *)accessPolicy         { return _accessPolicy; }
- (void)setAccessPolicy:(TTIOAccessPolicy *)policy { _accessPolicy = policy; }

@end
