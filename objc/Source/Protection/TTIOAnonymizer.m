#import "TTIOAnonymizer.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Spectra/TTIONMRSpectrum.h"
#import "Spectra/TTIOChromatogram.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOWrittenGenomicRun.h"

// Forward-declare the private class method on TTIOSpectralDataset
// that writes one genomic_runs subtree via the HDF5 fast path.
// Defined in TTIOSpectralDataset.m; not exposed in the public
// header but callable from within the framework.
@interface TTIOSpectralDataset (TTIOPrivateGenomicWrite)
+ (BOOL)writeGenomicRun:(TTIOWrittenGenomicRun *)run
                  toGroup:(TTIOHDF5Group *)group
                     name:(NSString *)name
                    error:(NSError **)error;
@end

#pragma mark - Policy

@implementation TTIOAnonymizationPolicy

- (instancetype)init
{
    self = [super init];
    if (self) {
        _rareMetaboliteThreshold = 0.05;
        _coarsenMzDecimals = -1;
        _coarsenChemicalShiftDecimals = -1;
        // M90.3 defaults
        _randomiseQualitiesConstant = 30;
    }
    return self;
}

@end

#pragma mark - Result

@implementation TTIOAnonymizationResult
@end

#pragma mark - Helpers

static BOOL isSAAV(TTIOIdentification *ident)
{
    NSString *upper = [ident.chemicalEntity uppercaseString];
    return ([upper rangeOfString:@"SAAV"].location != NSNotFound ||
            [upper rangeOfString:@"VARIANT"].location != NSNotFound);
}

static double *copyDoubleArray(TTIOSignalArray *arr)
{
    NSUInteger n = arr.length;
    double *out = (double *)malloc(n * sizeof(double));
    memcpy(out, arr.buffer.bytes, n * sizeof(double));
    return out;
}

static TTIOSignalArray *arrayFromDoubles(double *buf, NSUInteger n)
{
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    NSData *d = [NSData dataWithBytes:buf length:n * sizeof(double)];
    return [[TTIOSignalArray alloc] initWithBuffer:d length:n encoding:enc axis:nil];
}

static void roundArray(double *arr, NSUInteger n, NSInteger decimals)
{
    double scale = pow(10.0, (double)decimals);
    for (NSUInteger i = 0; i < n; i++) {
        arr[i] = round(arr[i] * scale) / scale;
    }
}

#pragma mark - Anonymizer

@implementation TTIOAnonymizer

+ (TTIOAnonymizationResult *)anonymizeDataset:(TTIOSpectralDataset *)source
                                   outputPath:(NSString *)outputPath
                                       policy:(TTIOAnonymizationPolicy *)policy
                                        error:(NSError **)error
{
    TTIOAnonymizationResult *result = [[TTIOAnonymizationResult alloc] init];
    NSMutableArray<NSString *> *appliedPolicies = [NSMutableArray array];

    NSArray<TTIOIdentification *> *identifications = source.identifications;

    // Build SAAV index set
    NSMutableSet<NSString *> *saavKeys = [NSMutableSet set];
    if (policy.redactSAAVSpectra) {
        for (TTIOIdentification *ident in identifications) {
            if (isSAAV(ident)) {
                NSString *key = [NSString stringWithFormat:@"%@:%lu",
                                 ident.runName, (unsigned long)ident.spectrumIndex];
                [saavKeys addObject:key];
            }
        }
    }

    // Rare metabolite lookup
    NSDictionary<NSString *, NSNumber *> *prevalence = policy.rareMetaboliteTable;

    // Process each run
    NSMutableDictionary<NSString *, TTIOAcquisitionRun *> *newRuns = [NSMutableDictionary dictionary];
    NSArray<NSString *> *runNames = [[source.msRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];

    for (NSString *runName in runNames) {
        TTIOAcquisitionRun *run = source.msRuns[runName];
        NSUInteger nSpectra = run.spectrumIndex.count;

        NSMutableArray *keptSpectra = [NSMutableArray array];

        for (NSUInteger i = 0; i < nSpectra; i++) {
            // SAAV redaction
            if (policy.redactSAAVSpectra) {
                NSString *key = [NSString stringWithFormat:@"%@:%lu", runName, (unsigned long)i];
                if ([saavKeys containsObject:key]) {
                    result.spectraRedacted++;
                    continue;
                }
            }

            NSError *specErr = nil;
            id specObj = [run spectrumAtIndex:i error:&specErr];
            if (!specObj) continue;

            if ([specObj isKindOfClass:[TTIOMassSpectrum class]]) {
                TTIOMassSpectrum *ms = (TTIOMassSpectrum *)specObj;
                NSUInteger n = ms.mzArray.length;
                double *mzBuf = copyDoubleArray(ms.mzArray);
                double *intBuf = copyDoubleArray(ms.intensityArray);

                if (policy.coarsenMzDecimals >= 0) {
                    roundArray(mzBuf, n, policy.coarsenMzDecimals);
                    result.mzValuesCoarsened += n;
                }

                if (policy.maskIntensityBelowQuantile > 0.0) {
                    double sorted[n];
                    memcpy(sorted, intBuf, n * sizeof(double));
                    for (NSUInteger a = 0; a < n; a++)
                        for (NSUInteger b = a + 1; b < n; b++)
                            if (sorted[a] > sorted[b]) {
                                double tmp = sorted[a]; sorted[a] = sorted[b]; sorted[b] = tmp;
                            }
                    NSUInteger qIdx = (NSUInteger)(policy.maskIntensityBelowQuantile * (double)(n - 1));
                    double threshold = sorted[qIdx];
                    for (NSUInteger j = 0; j < n; j++) {
                        if (intBuf[j] < threshold) {
                            intBuf[j] = 0.0;
                            result.intensitiesZeroed++;
                        }
                    }
                }

                if (policy.maskRareMetabolites && prevalence) {
                    for (TTIOIdentification *ident in identifications) {
                        if (![ident.runName isEqualToString:runName]) continue;
                        if (ident.spectrumIndex != i) continue;
                        NSNumber *prev = prevalence[ident.chemicalEntity];
                        if (prev && prev.doubleValue < policy.rareMetaboliteThreshold) {
                            memset(intBuf, 0, n * sizeof(double));
                            result.metabolitesMasked++;
                            break;
                        }
                    }
                }

                TTIOSignalArray *newMz = arrayFromDoubles(mzBuf, n);
                TTIOSignalArray *newInt = arrayFromDoubles(intBuf, n);
                free(mzBuf); free(intBuf);

                TTIOMassSpectrum *newSpec =
                    [[TTIOMassSpectrum alloc] initWithMzArray:newMz
                                               intensityArray:newInt
                                                      msLevel:ms.msLevel
                                                     polarity:ms.polarity
                                                   scanWindow:nil
                                                indexPosition:keptSpectra.count
                                              scanTimeSeconds:ms.scanTimeSeconds
                                                  precursorMz:ms.precursorMz
                                              precursorCharge:ms.precursorCharge
                                                        error:NULL];
                if (newSpec) [keptSpectra addObject:newSpec];
            }
        }

        TTIOAcquisitionRun *newRun =
            [[TTIOAcquisitionRun alloc] initWithSpectra:keptSpectra
                                          chromatograms:run.chromatograms
                                        acquisitionMode:run.acquisitionMode
                                       instrumentConfig:run.instrumentConfig];
        newRuns[runName] = newRun;
    }

    // Track which policies fired
    if (policy.redactSAAVSpectra && result.spectraRedacted > 0)
        [appliedPolicies addObject:@"redact_saav_spectra"];
    if (policy.coarsenMzDecimals >= 0 && result.mzValuesCoarsened > 0)
        [appliedPolicies addObject:@"coarsen_mz_decimals"];
    if (policy.maskIntensityBelowQuantile > 0.0 && result.intensitiesZeroed > 0)
        [appliedPolicies addObject:@"mask_intensity_below_quantile"];
    if (policy.maskRareMetabolites && result.metabolitesMasked > 0)
        [appliedPolicies addObject:@"mask_rare_metabolites"];

    NSString *title = source.title;
    if (policy.stripMetadataFields) {
        title = @"";
        result.metadataFieldsStripped = 1;
        [appliedPolicies addObject:@"strip_metadata_fields"];
    }

    result.policiesApplied = appliedPolicies;

    // Build provenance
    NSDictionary *params = @{
        @"policies": appliedPolicies,
        @"spectraRedacted": @(result.spectraRedacted),
        @"intensitiesZeroed": @(result.intensitiesZeroed),
        @"mzValuesCoarsened": @(result.mzValuesCoarsened),
        @"metabolitesMasked": @(result.metabolitesMasked),
        @"metadataFieldsStripped": @(result.metadataFieldsStripped),
    };
    TTIOProvenanceRecord *prov =
        [[TTIOProvenanceRecord alloc]
            initWithInputRefs:@[source.filePath ?: @""]
                     software:@"ttio anonymizer v0.4"
                   parameters:params
                   outputRefs:@[outputPath]
                timestampUnix:(int64_t)time(NULL)];

    // Write output
    TTIOSpectralDataset *out =
        [[TTIOSpectralDataset alloc]
            initWithTitle:title
       isaInvestigationId:source.isaInvestigationId
                   msRuns:newRuns
                  nmrRuns:@{}
          identifications:source.identifications
          quantifications:source.quantifications
        provenanceRecords:@[prov]
              transitions:nil];

    if (![out writeToFilePath:outputPath error:error]) return nil;

    // M90.3 — apply genomic policies and append /study/genomic_runs/
    // to the just-written file. Source.genomicRuns is iterated lazily
    // (M82 reader); we materialise reads into TTIOWrittenGenomicRun
    // objects with the requested transforms applied, then write each
    // subtree under the existing /study group via the HDF5 fast path.
    if (source.genomicRuns.count > 0) {
        if (![self _applyGenomicPolicies:source
                                  output:outputPath
                                  policy:policy
                                  result:result
                                   error:error]) {
            return nil;
        }
    }
    return result;
}


#pragma mark - M90.3 Genomic policies

+ (BOOL)_applyGenomicPolicies:(TTIOSpectralDataset *)source
                       output:(NSString *)outputPath
                       policy:(TTIOAnonymizationPolicy *)policy
                       result:(TTIOAnonymizationResult *)result
                        error:(NSError **)error
{
    // We need a mutable copy of the appliedPolicies list to track
    // M90.3 policy firings — the result property is `copy` so we
    // can't mutate it in place. Take ownership of the existing list
    // (likely an immutable NSArray) into a mutable shadow.
    NSMutableArray<NSString *> *applied =
        [NSMutableArray arrayWithArray:result.policiesApplied ?: @[]];

    NSArray<NSString *> *runNames =
        [[source.genomicRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];

    NSMutableDictionary<NSString *, TTIOWrittenGenomicRun *> *transformed =
        [NSMutableDictionary dictionary];

    for (NSString *runName in runNames) {
        TTIOGenomicRun *gr = source.genomicRuns[runName];
        NSUInteger n = gr.readCount;

        // Materialise per-read fields by iterating the lazy run.
        // O(N) reads — anonymizer is one-shot offline so the cost
        // is acceptable.
        NSMutableArray<NSString *> *readNames =
            [NSMutableArray arrayWithCapacity:n];
        NSMutableArray<NSString *> *cigars =
            [NSMutableArray arrayWithCapacity:n];
        NSMutableArray<NSData *> *sequencesList =
            [NSMutableArray arrayWithCapacity:n];
        NSMutableArray<NSMutableData *> *qualitiesList =
            [NSMutableArray arrayWithCapacity:n];
        NSMutableArray<NSString *> *mateChromosomes =
            [NSMutableArray arrayWithCapacity:n];
        NSMutableData *matePositionsData =
            [NSMutableData dataWithLength:n * sizeof(int64_t)];
        int64_t *matePositions = (int64_t *)matePositionsData.mutableBytes;
        NSMutableData *templateLengthsData =
            [NSMutableData dataWithLength:n * sizeof(int32_t)];
        int32_t *templateLengths =
            (int32_t *)templateLengthsData.mutableBytes;

        for (NSUInteger i = 0; i < n; i++) {
            NSError *readErr = nil;
            TTIOAlignedRead *r = [gr readAtIndex:i error:&readErr];
            if (!r) {
                if (error) *error = readErr;
                return NO;
            }
            [readNames addObject:r.readName ?: @""];
            [cigars    addObject:r.cigar ?: @""];
            NSData *seqBytes =
                [r.sequence dataUsingEncoding:NSASCIIStringEncoding] ?: [NSData data];
            [sequencesList addObject:seqBytes];
            NSMutableData *q = [r.qualities mutableCopy] ?: [NSMutableData data];
            [qualitiesList addObject:q];
            [mateChromosomes addObject:r.mateChromosome ?: @""];
            matePositions[i] = r.matePosition;
            templateLengths[i] = r.templateLength;
        }

        // ── strip_read_names ─────────────────────────────────────
        if (policy.stripReadNames) {
            for (NSUInteger i = 0; i < n; i++) {
                [readNames replaceObjectAtIndex:i withObject:@""];
            }
            result.readNamesStripped += n;
            if (![applied containsObject:@"strip_read_names"]) {
                [applied addObject:@"strip_read_names"];
            }
        }

        // ── randomise_qualities ──────────────────────────────────
        if (policy.randomiseQualities) {
            uint8_t k = policy.randomiseQualitiesConstant;
            for (NSUInteger i = 0; i < n; i++) {
                NSMutableData *q = qualitiesList[i];
                uint8_t *bytes = (uint8_t *)q.mutableBytes;
                memset(bytes, k, q.length);
            }
            result.qualitiesRandomised += n;
            if (![applied containsObject:@"randomise_qualities"]) {
                [applied addObject:@"randomise_qualities"];
            }
        }

        // ── mask_regions ─────────────────────────────────────────
        if (policy.maskRegions.count > 0) {
            for (NSUInteger i = 0; i < n; i++) {
                NSString *chromI = [gr.index chromosomeAt:i];
                int64_t posI = [gr.index positionAt:i];
                BOOL hit = NO;
                for (NSArray *region in policy.maskRegions) {
                    if (region.count != 3) continue;
                    NSString *rChr = region[0];
                    int64_t rStart = [region[1] longLongValue];
                    int64_t rEnd   = [region[2] longLongValue];
                    if ([chromI isEqualToString:rChr]
                        && posI >= rStart && posI <= rEnd) {
                        hit = YES;
                        break;
                    }
                }
                if (hit) {
                    NSMutableData *zeroSeq =
                        [NSMutableData dataWithLength:[sequencesList[i] length]];
                    [sequencesList replaceObjectAtIndex:i withObject:zeroSeq];
                    NSMutableData *q = qualitiesList[i];
                    memset(q.mutableBytes, 0, q.length);
                    result.readsInMaskedRegion += 1;
                }
            }
            if (![applied containsObject:@"mask_regions"]) {
                [applied addObject:@"mask_regions"];
            }
        }

        // ── Re-pack into the flat WrittenGenomicRun layout. ──────
        NSMutableData *lengthsData =
            [NSMutableData dataWithLength:n * sizeof(uint32_t)];
        uint32_t *lengths = (uint32_t *)lengthsData.mutableBytes;
        NSMutableData *offsetsData =
            [NSMutableData dataWithLength:n * sizeof(uint64_t)];
        uint64_t *offsets = (uint64_t *)offsetsData.mutableBytes;
        uint64_t running = 0;
        NSMutableData *sequencesFlat = [NSMutableData data];
        NSMutableData *qualitiesFlat = [NSMutableData data];
        for (NSUInteger i = 0; i < n; i++) {
            NSData *s = sequencesList[i];
            offsets[i] = running;
            lengths[i] = (uint32_t)s.length;
            running += s.length;
            [sequencesFlat appendData:s];
            [qualitiesFlat appendData:qualitiesList[i]];
        }

        // Repack positions / mapping_qualities / flags / chromosomes
        // from the source index (no per-read transform on these — only
        // sequences/qualities/read_names/cigars are touched).
        NSMutableData *positionsData =
            [NSMutableData dataWithLength:n * sizeof(int64_t)];
        int64_t *positions = (int64_t *)positionsData.mutableBytes;
        NSMutableData *mapqsData =
            [NSMutableData dataWithLength:n * sizeof(uint8_t)];
        uint8_t *mapqs = (uint8_t *)mapqsData.mutableBytes;
        NSMutableData *flagsData =
            [NSMutableData dataWithLength:n * sizeof(uint32_t)];
        uint32_t *flags = (uint32_t *)flagsData.mutableBytes;
        NSMutableArray<NSString *> *chromosomes =
            [NSMutableArray arrayWithCapacity:n];
        for (NSUInteger i = 0; i < n; i++) {
            positions[i] = [gr.index positionAt:i];
            mapqs[i]     = [gr.index mappingQualityAt:i];
            flags[i]     = [gr.index flagsAt:i];
            [chromosomes addObject:[gr.index chromosomeAt:i] ?: @""];
        }

        TTIOWrittenGenomicRun *written =
            [[TTIOWrittenGenomicRun alloc]
                initWithAcquisitionMode:gr.acquisitionMode
                           referenceUri:gr.referenceUri ?: @""
                               platform:gr.platform ?: @""
                             sampleName:gr.sampleName ?: @""
                              positions:positionsData
                       mappingQualities:mapqsData
                                  flags:flagsData
                              sequences:sequencesFlat
                              qualities:qualitiesFlat
                                offsets:offsetsData
                                lengths:lengthsData
                                 cigars:cigars
                              readNames:readNames
                        mateChromosomes:mateChromosomes
                          matePositions:matePositionsData
                        templateLengths:templateLengthsData
                            chromosomes:chromosomes
                     signalCompression:TTIOCompressionZlib];
        transformed[runName] = written;
    }

    // Open the just-written file and append /study/genomic_runs/.
    TTIOHDF5File *file =
        [TTIOHDF5File openAtPath:outputPath error:error];
    if (!file) return NO;
    TTIOHDF5Group *root = file.rootGroup;
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) { [file close]; return NO; }
    TTIOHDF5Group *gRunsGroup = nil;
    if ([study hasChildNamed:@"genomic_runs"]) {
        gRunsGroup = [study openGroupNamed:@"genomic_runs" error:error];
    } else {
        gRunsGroup = [study createGroupNamed:@"genomic_runs" error:error];
    }
    if (!gRunsGroup) { [file close]; return NO; }
    NSArray<NSString *> *gNames =
        [transformed.allKeys sortedArrayUsingSelector:@selector(compare:)];
    if (![gRunsGroup setStringAttribute:@"_run_names"
                                  value:[gNames componentsJoinedByString:@","]
                                  error:error]) {
        [file close]; return NO;
    }
    for (NSString *gName in gNames) {
        TTIOWrittenGenomicRun *wgr = transformed[gName];
        if (![TTIOSpectralDataset writeGenomicRun:wgr
                                            toGroup:gRunsGroup
                                               name:gName
                                              error:error]) {
            [file close];
            return NO;
        }
    }

    // Set the opt_genomic feature flag so the reader picks up the
    // genomic_runs subtree on round-trip.
    NSArray *currentFeatures = [TTIOFeatureFlags featuresForRoot:root] ?: @[];
    if (![currentFeatures containsObject:[TTIOFeatureFlags featureOptGenomic]]) {
        NSMutableArray *updated = [currentFeatures mutableCopy];
        [updated addObject:[TTIOFeatureFlags featureOptGenomic]];
        NSString *version = [TTIOFeatureFlags formatVersionForRoot:root] ?: @"1.4";
        if (![TTIOFeatureFlags writeFormatVersion:version
                                          features:updated
                                            toRoot:root
                                             error:error]) {
            [file close]; return NO;
        }
    }

    [file close];

    result.policiesApplied = applied;
    return YES;
}

@end
