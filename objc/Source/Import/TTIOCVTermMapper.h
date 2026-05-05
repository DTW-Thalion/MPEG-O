/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_CV_TERM_MAPPER_H
#define TTIO_CV_TERM_MAPPER_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"
#import "ValueClasses/TTIOCVParam.h"

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOCVTermMapper.h</p>
 *
 * <p>Maps PSI-MS controlled-vocabulary accessions to TTIO model
 * values. The PSI-MS OBO
 * (<code>https://www.psidev.info/psi-ms.obo</code>) defines thousands
 * of accessions; <code>TTIOCVTermMapper</code> hardcodes mappings for
 * the ~50 terms needed to import a typical mzML file, covering data
 * types, compression, array roles, MS level, polarity, scan window,
 * TIC / base peak, retention time, and precursor information.
 * Unknown accessions are passed through as raw
 * <code>TTIOCVParam</code> objects so ontology annotations survive
 * the round-trip even when TTIO does not interpret them
 * directly.</p>
 *
 * <p><strong>Sentinel return values:</strong></p>
 * <ul>
 *  <li><code>+precisionForAccession:</code> returns
 *      <code>TTIOPrecisionFloat64</code> for unknown.</li>
 *  <li><code>+compressionForAccession:</code> returns
 *      <code>TTIOCompressionNone</code> for unknown.</li>
 *  <li><code>+signalArrayNameForAccession:</code> returns
 *      <code>nil</code> for unknown.</li>
 * </ul>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.cv_term_mapper</code><br/>
 * Java:
 * <code>global.thalion.ttio.importers.CVTermMapper</code></p>
 */
@interface TTIOCVTermMapper : NSObject

#pragma mark - Data type accessions

/** MS:1000521 -> Float32, MS:1000523 -> Float64. Default Float64. */
+ (TTIOPrecision)precisionForAccession:(NSString *)acc;

#pragma mark - Compression accessions

/** MS:1000574 -> Zlib, MS:1000576 -> None. Default None. */
+ (TTIOCompression)compressionForAccession:(NSString *)acc;

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

#pragma mark - MS/MS activation-method accessions

/** Resolve a PSI-MS activation-method accession to a value from the
 *  TTIOActivationMethod enum. Returns TTIOActivationMethodNone for any
 *  accession that is not a recognised activation method.
 *  Caller can distinguish "unknown" from an explicit NONE by checking
 *  +isActivationMethodAccession: first. */
+ (TTIOActivationMethod)activationMethodForAccession:(NSString *)acc;
+ (BOOL)isActivationMethodAccession:(NSString *)acc;

/** Reverse of +activationMethodForAccession: for the mzML writer. Returns
 *  the PSI-MS accession for a concrete TTIOActivationMethod, or nil for
 *  TTIOActivationMethodNone. Callers gate emission of the `<activation>`
 *  cvParam on a non-nil return here (and ms_level >= 2). */
+ (NSString *)activationAccessionForMethod:(TTIOActivationMethod)method;

/** Human-readable name paired with +activationAccessionForMethod:, used
 *  as the `name=".."` attribute in the emitted cvParam. */
+ (NSString *)activationNameForMethod:(TTIOActivationMethod)method;

#pragma mark - Isolation-window cvParam accessions

+ (BOOL)isIsolationWindowTargetMzAccession:(NSString *)acc;  // MS:1000827
+ (BOOL)isIsolationWindowLowerOffsetAccession:(NSString *)acc; // MS:1000828
+ (BOOL)isIsolationWindowUpperOffsetAccession:(NSString *)acc; // MS:1000829

#pragma mark - nmrCV accessions

+ (BOOL)isSpectrometerFrequencyAccession:(NSString *)acc; // NMR:1000001
+ (BOOL)isNucleusAccession:(NSString *)acc;               // NMR:1000002
+ (BOOL)isNumberOfScansAccession:(NSString *)acc;         // NMR:1000003
+ (BOOL)isDwellTimeAccession:(NSString *)acc;             // NMR:1000004
+ (BOOL)isSweepWidthAccession:(NSString *)acc;            // NMR:1400014

#pragma mark - Passthrough

/** Build a raw TTIOCVParam for an unrecognized accession. */
+ (TTIOCVParam *)cvParamFromAccession:(NSString *)acc
                                 name:(NSString *)name
                                value:(NSString *)value
                          ontologyRef:(NSString *)ontRef
                                 unit:(NSString *)unitAcc;

@end

#endif /* TTIO_CV_TERM_MAPPER_H */
