/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef MPGO_CV_TERM_MAPPER_H
#define MPGO_CV_TERM_MAPPER_H

#import <Foundation/Foundation.h>
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOCVParam.h"

/**
 * Maps PSI-MS controlled-vocabulary accessions to MPGO model values.
 *
 * The PSI-MS OBO (https://www.psidev.info/psi-ms.obo) defines thousands
 * of accessions. MPGOCVTermMapper hardcodes mappings for the ~50 terms
 * needed to import a typical mzML file, covering data types, compression,
 * array roles, MS level, polarity, scan window, TIC/base peak, retention
 * time, and precursor information. Unknown accessions are passed through
 * as raw MPGOCVParam objects so ontology annotations survive the
 * round-trip even when MPGO does not interpret them directly.
 *
 * Sentinel return values:
 *   - -precisionForAccession: returns MPGOPrecisionFloat64 for unknown
 *   - -compressionForAccession: returns MPGOCompressionNone for unknown
 *   - -signalArrayNameForAccession: returns nil for unknown
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.importers.cv_term_mapper
 *   Java:   com.dtwthalion.mpgo.importers.CVTermMapper
 */
@interface MPGOCVTermMapper : NSObject

#pragma mark - Data type accessions

/** MS:1000521 -> Float32, MS:1000523 -> Float64. Default Float64. */
+ (MPGOPrecision)precisionForAccession:(NSString *)acc;

#pragma mark - Compression accessions

/** MS:1000574 -> Zlib, MS:1000576 -> None. Default None. */
+ (MPGOCompression)compressionForAccession:(NSString *)acc;

#pragma mark - Array role accessions

/** MS:1000514 -> @"mz", MS:1000515 -> @"intensity", etc. nil for unknown. */
+ (NSString *)signalArrayNameForAccession:(NSString *)acc;

#pragma mark - Spectrum metadata accessions

+ (BOOL)isMSLevelAccession:(NSString *)acc;          // MS:1000511
+ (BOOL)isPositivePolarityAccession:(NSString *)acc; // MS:1000130
+ (BOOL)isNegativePolarityAccession:(NSString *)acc; // MS:1000129
+ (BOOL)isScanWindowLowerAccession:(NSString *)acc;  // MS:1000501
+ (BOOL)isScanWindowUpperAccession:(NSString *)acc;  // MS:1000500
+ (BOOL)isTotalIonCurrentAccession:(NSString *)acc;  // MS:1000285
+ (BOOL)isBasePeakMzAccession:(NSString *)acc;       // MS:1000504
+ (BOOL)isBasePeakIntensityAccession:(NSString *)acc;// MS:1000505
+ (BOOL)isScanStartTimeAccession:(NSString *)acc;    // MS:1000016
+ (BOOL)isSelectedIonMzAccession:(NSString *)acc;    // MS:1000744
+ (BOOL)isChargeStateAccession:(NSString *)acc;      // MS:1000041

#pragma mark - Chromatogram role accessions

+ (BOOL)isTotalIonChromatogramAccession:(NSString *)acc;     // MS:1000235
+ (BOOL)isSelectedReactionMonitoringAccession:(NSString *)acc;// MS:1001473

#pragma mark - M74: MS/MS activation-method accessions

/** Resolve a PSI-MS activation-method accession to a value from the
 *  MPGOActivationMethod enum. Returns MPGOActivationMethodNone for any
 *  accession that is not a recognised activation method.
 *  Caller can distinguish "unknown" from an explicit NONE by checking
 *  +isActivationMethodAccession: first. */
+ (MPGOActivationMethod)activationMethodForAccession:(NSString *)acc;
+ (BOOL)isActivationMethodAccession:(NSString *)acc;

#pragma mark - M74: isolation-window cvParam accessions

+ (BOOL)isIsolationWindowTargetMzAccession:(NSString *)acc;  // MS:1000827
+ (BOOL)isIsolationWindowLowerOffsetAccession:(NSString *)acc; // MS:1000828
+ (BOOL)isIsolationWindowUpperOffsetAccession:(NSString *)acc; // MS:1000829

#pragma mark - nmrCV accessions (Milestone 13)

+ (BOOL)isSpectrometerFrequencyAccession:(NSString *)acc; // NMR:1000001
+ (BOOL)isNucleusAccession:(NSString *)acc;               // NMR:1000002
+ (BOOL)isNumberOfScansAccession:(NSString *)acc;         // NMR:1000003
+ (BOOL)isDwellTimeAccession:(NSString *)acc;             // NMR:1000004
+ (BOOL)isSweepWidthAccession:(NSString *)acc;            // NMR:1400014

#pragma mark - Passthrough

/** Build a raw MPGOCVParam for an unrecognized accession. */
+ (MPGOCVParam *)cvParamFromAccession:(NSString *)acc
                                 name:(NSString *)name
                                value:(NSString *)value
                          ontologyRef:(NSString *)ontRef
                                 unit:(NSString *)unitAcc;

@end

#endif /* MPGO_CV_TERM_MAPPER_H */
