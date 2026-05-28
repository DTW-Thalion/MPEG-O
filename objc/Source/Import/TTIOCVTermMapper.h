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

/**
 * Resolve a PSI-MS data-type accession to a `TTIOPrecision` enum value.
 *
 * Recognised mappings: MS:1000521 -> `TTIOPrecisionFloat32`,
 * MS:1000523 -> `TTIOPrecisionFloat64`, MS:1000519 -> `TTIOPrecisionInt32`,
 * MS:1000522 -> `TTIOPrecisionInt64`. Any other accession (including `nil`)
 * falls back to `TTIOPrecisionFloat64` so unknown precisions decode as
 * the safe widest type.
 *
 * @param acc  PSI-MS accession string, e.g. `@"MS:1000521"`.
 * @return Mapped `TTIOPrecision` value, or `TTIOPrecisionFloat64` for
 *         unknown accessions.
 */
+ (TTIOPrecision)precisionForAccession:(NSString *)acc;

#pragma mark - Compression accessions

/**
 * Resolve a PSI-MS compression accession to a `TTIOCompression` enum value.
 *
 * Recognised: MS:1000574 -> `TTIOCompressionZlib`,
 * MS:1000576 -> `TTIOCompressionNone`. Any other accession falls back to
 * `TTIOCompressionNone` (the spec-default for an absent compression cvParam).
 *
 * @param acc  PSI-MS accession string, e.g. `@"MS:1000574"`.
 * @return Mapped `TTIOCompression` value, or `TTIOCompressionNone` for
 *         unknown accessions.
 */
+ (TTIOCompression)compressionForAccession:(NSString *)acc;

#pragma mark - Array role accessions

/**
 * Resolve a PSI-MS array-role accession to a TTIO signal-array name.
 *
 * Recognised mappings: MS:1000514 -> `@"mz"`, MS:1000515 -> `@"intensity"`,
 * MS:1000516 -> `@"charge"`, MS:1000517 -> `@"signal_to_noise"`,
 * MS:1000595 -> `@"time"`, MS:1000617 -> `@"wavelength"`,
 * MS:1000820 -> `@"ion_mobility"`. Unknown accessions return `nil` so the
 * caller can preserve them as raw `TTIOCVParam` annotations.
 *
 * @param acc  PSI-MS accession string, e.g. `@"MS:1000514"`.
 * @return Signal-array name, or `nil` if the accession is unrecognised.
 */
+ (NSString *)signalArrayNameForAccession:(NSString *)acc;

#pragma mark - Spectrum metadata accessions

/**
 * Whether the given accession identifies the MS scan level term (MS:1000511).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000511"`.
 */
+ (BOOL)isMSLevelAccession:(NSString *)acc;

/**
 * Whether the given accession identifies positive-ion polarity (MS:1000130).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000130"`.
 */
+ (BOOL)isPositivePolarityAccession:(NSString *)acc;

/**
 * Whether the given accession identifies negative-ion polarity (MS:1000129).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000129"`.
 */
+ (BOOL)isNegativePolarityAccession:(NSString *)acc;

/**
 * Whether the given accession identifies the scan-window lower limit (MS:1000501).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000501"`.
 */
+ (BOOL)isScanWindowLowerAccession:(NSString *)acc;

/**
 * Whether the given accession identifies the scan-window upper limit (MS:1000500).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000500"`.
 */
+ (BOOL)isScanWindowUpperAccession:(NSString *)acc;

/**
 * Whether the given accession identifies a total-ion-current term (MS:1000285).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000285"`.
 */
+ (BOOL)isTotalIonCurrentAccession:(NSString *)acc;

/**
 * Whether the given accession identifies a base-peak m/z term (MS:1000504).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000504"`.
 */
+ (BOOL)isBasePeakMzAccession:(NSString *)acc;

/**
 * Whether the given accession identifies a base-peak intensity term (MS:1000505).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000505"`.
 */
+ (BOOL)isBasePeakIntensityAccession:(NSString *)acc;

/**
 * Whether the given accession identifies a scan start-time term (MS:1000016).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000016"`.
 */
+ (BOOL)isScanStartTimeAccession:(NSString *)acc;

/**
 * Whether the given accession identifies a selected-ion m/z term (MS:1000744).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000744"`.
 */
+ (BOOL)isSelectedIonMzAccession:(NSString *)acc;

/**
 * Whether the given accession identifies a charge-state term (MS:1000041).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000041"`.
 */
+ (BOOL)isChargeStateAccession:(NSString *)acc;

#pragma mark - Chromatogram role accessions

/**
 * Whether the given accession identifies a total-ion-chromatogram term
 * (MS:1000235).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000235"`.
 */
+ (BOOL)isTotalIonChromatogramAccession:(NSString *)acc;

/**
 * Whether the given accession identifies a selected-reaction-monitoring
 * chromatogram term (MS:1001473).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1001473"`.
 */
+ (BOOL)isSelectedReactionMonitoringAccession:(NSString *)acc;

#pragma mark - MS/MS activation-method accessions

/**
 * Resolve a PSI-MS activation-method accession to a `TTIOActivationMethod`.
 *
 * Returns `TTIOActivationMethodNone` for any accession not in the
 * recognised set (CID, HCD, ETD, ECD, UVPD, BIRD, PD, PQD, SID, etc).
 * Callers that need to distinguish "unknown accession" from an explicit
 * `TTIOActivationMethodNone` should pre-gate the lookup with
 * `+isActivationMethodAccession:`.
 *
 * @param acc  PSI-MS accession string, e.g. `@"MS:1000133"` (CID).
 * @return Mapped `TTIOActivationMethod` value, or
 *         `TTIOActivationMethodNone` for unknown.
 */
+ (TTIOActivationMethod)activationMethodForAccession:(NSString *)acc;

/**
 * Whether the given accession is a recognised PSI-MS activation-method
 * term.
 *
 * Companion predicate to `+activationMethodForAccession:` — lets callers
 * tell unknown accessions apart from an explicit `None` value.
 *
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is one of the activation-method accessions known
 *         to this mapper.
 */
+ (BOOL)isActivationMethodAccession:(NSString *)acc;

/**
 * Resolve a `TTIOActivationMethod` to its canonical PSI-MS accession.
 *
 * Reverse of `+activationMethodForAccession:`, used by the mzML writer to
 * emit `<activation>` cvParam blocks. Callers should gate emission of
 * the cvParam on a non-`nil` return here (and `ms_level >= 2`).
 *
 * @param method  `TTIOActivationMethod` enum value.
 * @return PSI-MS accession string (e.g. `@"MS:1000133"` for CID), or
 *         `nil` for `TTIOActivationMethodNone`.
 */
+ (NSString *)activationAccessionForMethod:(TTIOActivationMethod)method;

/**
 * Resolve a `TTIOActivationMethod` to its PSI-MS human-readable name.
 *
 * Paired with `+activationAccessionForMethod:` for emitting the
 * `name="..."` attribute on the activation cvParam in mzML output.
 *
 * @param method  `TTIOActivationMethod` enum value.
 * @return Human-readable activation-method name (e.g. `@"collision-induced
 *         dissociation"` for CID), or `nil` for `TTIOActivationMethodNone`.
 */
+ (NSString *)activationNameForMethod:(TTIOActivationMethod)method;

#pragma mark - Isolation-window cvParam accessions

/**
 * Whether the given accession identifies the isolation-window target
 * m/z term (MS:1000827).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000827"`.
 */
+ (BOOL)isIsolationWindowTargetMzAccession:(NSString *)acc;

/**
 * Whether the given accession identifies the isolation-window lower
 * offset term (MS:1000828).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000828"`.
 */
+ (BOOL)isIsolationWindowLowerOffsetAccession:(NSString *)acc;

/**
 * Whether the given accession identifies the isolation-window upper
 * offset term (MS:1000829).
 * @param acc  PSI-MS accession string.
 * @return YES iff `acc` is `@"MS:1000829"`.
 */
+ (BOOL)isIsolationWindowUpperOffsetAccession:(NSString *)acc;

#pragma mark - nmrCV accessions

/**
 * Whether the given accession identifies an NMR spectrometer-frequency
 * term (NMR:1000001).
 * @param acc  nmrCV accession string.
 * @return YES iff `acc` is `@"NMR:1000001"`.
 */
+ (BOOL)isSpectrometerFrequencyAccession:(NSString *)acc;

/**
 * Whether the given accession identifies an NMR nucleus-type term
 * (NMR:1000002).
 * @param acc  nmrCV accession string.
 * @return YES iff `acc` is `@"NMR:1000002"`.
 */
+ (BOOL)isNucleusAccession:(NSString *)acc;

/**
 * Whether the given accession identifies an NMR number-of-scans term
 * (NMR:1000003).
 * @param acc  nmrCV accession string.
 * @return YES iff `acc` is `@"NMR:1000003"`.
 */
+ (BOOL)isNumberOfScansAccession:(NSString *)acc;

/**
 * Whether the given accession identifies an NMR dwell-time term
 * (NMR:1000004).
 * @param acc  nmrCV accession string.
 * @return YES iff `acc` is `@"NMR:1000004"`.
 */
+ (BOOL)isDwellTimeAccession:(NSString *)acc;

/**
 * Whether the given accession identifies an NMR sweep-width term
 * (NMR:1400014).
 * @param acc  nmrCV accession string.
 * @return YES iff `acc` is `@"NMR:1400014"`.
 */
+ (BOOL)isSweepWidthAccession:(NSString *)acc;

#pragma mark - Passthrough

/**
 * Build a raw `TTIOCVParam` for an unrecognised accession.
 *
 * Used by the import pipeline as the catch-all that preserves CV
 * annotations TTIO does not interpret — keeps ontology round-trips
 * lossless even when this mapper has no specific handler.
 *
 * @param acc      Accession string (e.g. `@"MS:9999999"`).
 * @param name     Human-readable CV term name from the source document.
 * @param value    Literal value attribute, or empty string if none.
 * @param ontRef   Ontology prefix (`@"MS"`, `@"NMR"`, `@"UO"`, etc).
 * @param unitAcc  Unit accession (e.g. `@"UO:0000010"` for seconds), or
 *                 empty string if none.
 * @return Newly allocated `TTIOCVParam` instance populated from the
 *         supplied fields.
 */
+ (TTIOCVParam *)cvParamFromAccession:(NSString *)acc
                                 name:(NSString *)name
                                value:(NSString *)value
                          ontologyRef:(NSString *)ontRef
                                 unit:(NSString *)unitAcc;

@end

#endif /* TTIO_CV_TERM_MAPPER_H */
