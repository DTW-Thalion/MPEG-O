#ifndef TTIO_ANONYMIZER_H
#define TTIO_ANONYMIZER_H

#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;

/**
 * <heading>TTIOAnonymizationPolicy</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Protection/TTIOAnonymizer.h</p>
 *
 * <p>Caller-supplied policy describing which anonymisation
 * transforms to apply. Passed to
 * <code>+[TTIOAnonymizer anonymizeDataset:...]</code> alongside the
 * source dataset; the anonymiser writes a new <code>.tio</code>
 * file. The original is never modified.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.anonymization</code><br/>
 * Java:
 * <code>global.thalion.ttio.protection.Anonymizer</code></p>
 *
 * <p>Spectral anonymisation transforms.</p>
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
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.anonymization
 *   Java:   global.thalion.ttio.protection.Anonymizer
 */
@interface TTIOAnonymizationPolicy : NSObject

@property (nonatomic) BOOL redactSAAVSpectra;
@property (nonatomic) double maskIntensityBelowQuantile;  // 0.0 = disabled
@property (nonatomic) BOOL maskRareMetabolites;
@property (nonatomic) double rareMetaboliteThreshold;     // default 0.05
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *rareMetaboliteTable;
@property (nonatomic) NSInteger coarsenMzDecimals;        // -1 = disabled
@property (nonatomic) NSInteger coarsenChemicalShiftDecimals; // -1 = disabled
@property (nonatomic) BOOL stripMetadataFields;

// Genomic anonymisation policies. When source has no
// genomic_runs, these are silent no-ops.

/** Replace every read_name on every genomic run with the empty
 *  string. Other genomic fields are preserved. */
@property (nonatomic) BOOL stripReadNames;

/** Replace every per-base Phred quality score with a single
 *  caller-specified constant (default 30). The replacement is
 *  deterministic per-read so anonymised .tio files stay
 *  reproducible. */
@property (nonatomic) BOOL randomiseQualities;

/** The per-base byte (Phred score) substituted in by
 *  randomiseQualities. Defaults to 30. */
@property (nonatomic) uint8_t randomiseQualitiesConstant;

/** When set (non-nil NSNumber), randomiseQualities draws per-byte
 *  Phred scores from a deterministic RNG seeded with this 64-bit
 *  value. Range is [0, 93] (SAM spec). Reproducible within the
 *  ObjC implementation: same seed → same byte sequence. When nil
 *  (default), the constant-replacement path is used.
 *
 *  Cross-language byte equality with numpy's PCG64 is NOT a goal —
 *  ObjC's RNG is a self-contained xoshiro256** so seeded outputs
 *  are reproducible within ObjC only. */
@property (nonatomic, copy, nullable) NSNumber *randomiseQualitiesSeed;

/** A list of (chromosome, start, end) tuples; any read whose
 *  mapping position falls in any region has its sequence and
 *  qualities bytes zeroed (kept in the index so downstream tooling
 *  iterating by index still sees N reads). Each entry is an
 *  NSArray of three elements: NSString chr, NSNumber start (int64),
 *  NSNumber end (int64). nil means "no regions to mask". */
@property (nonatomic, copy) NSArray<NSArray *> *maskRegions;

@end

@interface TTIOAnonymizationResult : NSObject

@property (nonatomic) NSUInteger spectraRedacted;
@property (nonatomic) NSUInteger intensitiesZeroed;
@property (nonatomic) NSUInteger mzValuesCoarsened;
@property (nonatomic) NSUInteger chemicalShiftValuesCoarsened;
@property (nonatomic) NSUInteger metabolitesMasked;
@property (nonatomic) NSUInteger metadataFieldsStripped;
// Genomic counters. Populated when the corresponding policy is
// enabled and the source has genomic runs.
@property (nonatomic) NSUInteger readNamesStripped;
@property (nonatomic) NSUInteger qualitiesRandomised;
@property (nonatomic) NSUInteger readsInMaskedRegion;
@property (nonatomic, copy) NSArray<NSString *> *policiesApplied;

@end

@interface TTIOAnonymizer : NSObject

/**
 * Anonymize ``source`` under ``policy`` and write to ``outputPath``.
 * Returns the result summary or nil on failure.
 */
+ (TTIOAnonymizationResult *)anonymizeDataset:(TTIOSpectralDataset *)source
                                   outputPath:(NSString *)outputPath
                                       policy:(TTIOAnonymizationPolicy *)policy
                                        error:(NSError **)error;

@end

#endif /* TTIO_ANONYMIZER_H */
