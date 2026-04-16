#import "MPGOAnonymizer.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOIdentification.h"
#import "Dataset/MPGOProvenanceRecord.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Spectra/MPGOChromatogram.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOFeatureFlags.h"

#pragma mark - Policy

@implementation MPGOAnonymizationPolicy

- (instancetype)init
{
    self = [super init];
    if (self) {
        _rareMetaboliteThreshold = 0.05;
        _coarsenMzDecimals = -1;
        _coarsenChemicalShiftDecimals = -1;
    }
    return self;
}

@end

#pragma mark - Result

@implementation MPGOAnonymizationResult
@end

#pragma mark - Helpers

static BOOL isSAAV(MPGOIdentification *ident)
{
    NSString *upper = [ident.chemicalEntity uppercaseString];
    return ([upper rangeOfString:@"SAAV"].location != NSNotFound ||
            [upper rangeOfString:@"VARIANT"].location != NSNotFound);
}

static double *copyDoubleArray(MPGOSignalArray *arr)
{
    NSUInteger n = arr.length;
    double *out = (double *)malloc(n * sizeof(double));
    memcpy(out, arr.buffer.bytes, n * sizeof(double));
    return out;
}

static MPGOSignalArray *arrayFromDoubles(double *buf, NSUInteger n)
{
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    NSData *d = [NSData dataWithBytes:buf length:n * sizeof(double)];
    return [[MPGOSignalArray alloc] initWithBuffer:d length:n encoding:enc axis:nil];
}

static void roundArray(double *arr, NSUInteger n, NSInteger decimals)
{
    double scale = pow(10.0, (double)decimals);
    for (NSUInteger i = 0; i < n; i++) {
        arr[i] = round(arr[i] * scale) / scale;
    }
}

#pragma mark - Anonymizer

@implementation MPGOAnonymizer

+ (MPGOAnonymizationResult *)anonymizeDataset:(MPGOSpectralDataset *)source
                                   outputPath:(NSString *)outputPath
                                       policy:(MPGOAnonymizationPolicy *)policy
                                        error:(NSError **)error
{
    MPGOAnonymizationResult *result = [[MPGOAnonymizationResult alloc] init];
    NSMutableArray<NSString *> *appliedPolicies = [NSMutableArray array];

    NSArray<MPGOIdentification *> *identifications = source.identifications;

    // Build SAAV index set
    NSMutableSet<NSString *> *saavKeys = [NSMutableSet set];
    if (policy.redactSAAVSpectra) {
        for (MPGOIdentification *ident in identifications) {
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
    NSMutableDictionary<NSString *, MPGOAcquisitionRun *> *newRuns = [NSMutableDictionary dictionary];
    NSArray<NSString *> *runNames = [[source.msRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];

    for (NSString *runName in runNames) {
        MPGOAcquisitionRun *run = source.msRuns[runName];
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

            if ([specObj isKindOfClass:[MPGOMassSpectrum class]]) {
                MPGOMassSpectrum *ms = (MPGOMassSpectrum *)specObj;
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
                    for (MPGOIdentification *ident in identifications) {
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

                MPGOSignalArray *newMz = arrayFromDoubles(mzBuf, n);
                MPGOSignalArray *newInt = arrayFromDoubles(intBuf, n);
                free(mzBuf); free(intBuf);

                MPGOMassSpectrum *newSpec =
                    [[MPGOMassSpectrum alloc] initWithMzArray:newMz
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

        MPGOAcquisitionRun *newRun =
            [[MPGOAcquisitionRun alloc] initWithSpectra:keptSpectra
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
    MPGOProvenanceRecord *prov =
        [[MPGOProvenanceRecord alloc]
            initWithInputRefs:@[source.filePath ?: @""]
                     software:@"mpeg-o anonymizer v0.4"
                   parameters:params
                   outputRefs:@[outputPath]
                timestampUnix:(int64_t)time(NULL)];

    // Write output
    MPGOSpectralDataset *out =
        [[MPGOSpectralDataset alloc]
            initWithTitle:title
       isaInvestigationId:source.isaInvestigationId
                   msRuns:newRuns
                  nmrRuns:@{}
          identifications:source.identifications
          quantifications:source.quantifications
        provenanceRecords:@[prov]
              transitions:nil];

    if (![out writeToFilePath:outputPath error:error]) return nil;
    return result;
}

@end
