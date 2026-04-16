#ifndef MPGO_ANONYMIZER_H
#define MPGO_ANONYMIZER_H

#import <Foundation/Foundation.h>

@class MPGOSpectralDataset;

/**
 * Milestone 28 — spectral anonymization.
 *
 * Applies caller-selected policies to a dataset and writes a new
 * ``.mpgo`` file. The original is never modified.
 *
 * Supported policies:
 *   redactSAAVSpectra           — remove spectra with SAAV identifications
 *   maskIntensityBelowQuantile  — zero intensities below a percentile
 *   maskRareMetabolites         — suppress rare-metabolite signals
 *   coarsenMzDecimals           — reduce m/z precision
 *   coarsenChemicalShiftDecimals — reduce ppm precision (NMR)
 *   stripMetadataFields         — remove operator/serial/source/timestamps
 *
 * Output carries the ``opt_anonymized`` feature flag and a
 * ``ProvenanceRecord`` documenting which policies ran.
 */
@interface MPGOAnonymizationPolicy : NSObject

@property (nonatomic) BOOL redactSAAVSpectra;
@property (nonatomic) double maskIntensityBelowQuantile;  // 0.0 = disabled
@property (nonatomic) BOOL maskRareMetabolites;
@property (nonatomic) double rareMetaboliteThreshold;     // default 0.05
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *rareMetaboliteTable;
@property (nonatomic) NSInteger coarsenMzDecimals;        // -1 = disabled
@property (nonatomic) NSInteger coarsenChemicalShiftDecimals; // -1 = disabled
@property (nonatomic) BOOL stripMetadataFields;

@end

@interface MPGOAnonymizationResult : NSObject

@property (nonatomic) NSUInteger spectraRedacted;
@property (nonatomic) NSUInteger intensitiesZeroed;
@property (nonatomic) NSUInteger mzValuesCoarsened;
@property (nonatomic) NSUInteger chemicalShiftValuesCoarsened;
@property (nonatomic) NSUInteger metabolitesMasked;
@property (nonatomic) NSUInteger metadataFieldsStripped;
@property (nonatomic, copy) NSArray<NSString *> *policiesApplied;

@end

@interface MPGOAnonymizer : NSObject

/**
 * Anonymize ``source`` under ``policy`` and write to ``outputPath``.
 * Returns the result summary or nil on failure.
 */
+ (MPGOAnonymizationResult *)anonymizeDataset:(MPGOSpectralDataset *)source
                                   outputPath:(NSString *)outputPath
                                       policy:(MPGOAnonymizationPolicy *)policy
                                        error:(NSError **)error;

@end

#endif /* MPGO_ANONYMIZER_H */
