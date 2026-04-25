/*
 * TTI-O Objective-C Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_FEATURE_H
#define TTIO_FEATURE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A feature-level observation: a peak detected in one run, with
 * retention time + m/z + charge + per-sample abundances.
 *
 * Sits between {@link TTIOIdentification} (spectrum-level) and
 * {@link TTIOQuantification} (entity-level): the row-level record
 * required by mzTab's PEP section (peptide-level quantification in
 * the 1.0 proteomics dialect) and by mzTab-M's SMF/SME sections
 * (small-molecule feature + evidence in the 2.0.0-M metabolomics
 * dialect).
 *
 * API status: Provisional (v0.12.0 M78).
 *
 * Cross-language equivalents:
 *   Python: ttio.feature.Feature
 *   Java:   com.dtwthalion.tio.Feature
 */
@interface TTIOFeature : NSObject <NSCopying>

@property (nonatomic, readonly, copy) NSString *featureId;              // unique within file
@property (nonatomic, readonly, copy) NSString *runName;                // acquisition run
@property (nonatomic, readonly, copy) NSString *chemicalEntity;         // peptide seq, CHEBI id, formula
@property (nonatomic, readonly)       double    retentionTimeSeconds;   // apex retention time
@property (nonatomic, readonly)       double    expMassToCharge;        // experimental precursor m/z
@property (nonatomic, readonly)       NSInteger charge;                 // precursor charge
@property (nonatomic, readonly, copy) NSString *adductIon;              // e.g. "[M+H]1+"; empty for peptides
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSNumber *> *abundances;  // sample label → abundance
@property (nonatomic, readonly, copy) NSArray<NSString *> *evidenceRefs;

- (instancetype)initWithFeatureId:(NSString *)featureId
                          runName:(NSString *)runName
                   chemicalEntity:(NSString *)chemicalEntity
             retentionTimeSeconds:(double)rtSeconds
                  expMassToCharge:(double)mz
                           charge:(NSInteger)charge
                        adductIon:(nullable NSString *)adductIon
                       abundances:(nullable NSDictionary<NSString *, NSNumber *> *)abundances
                     evidenceRefs:(nullable NSArray<NSString *> *)evidenceRefs;

/** Minimal constructor; numeric + container fields default to empty/zero. */
+ (instancetype)featureWithId:(NSString *)featureId
                      runName:(NSString *)runName
               chemicalEntity:(NSString *)chemicalEntity;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_FEATURE_H */
