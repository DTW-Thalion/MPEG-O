/*
 * TTIOFeature.h
 * TTI-O Objective-C Implementation
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIO_FEATURE_H
#define TTIO_FEATURE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <heading>TTIOFeature</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying</p>
 * <p><em>Declared In:</em> Dataset/TTIOFeature.h</p>
 *
 * <p>A feature-level observation: a peak detected in one run, with
 * retention time, m/z, charge, and per-sample abundances. Sits
 * between {@link TTIOIdentification} (spectrum-level) and
 * {@link TTIOQuantification} (entity-level): the row-level record
 * required by mzTab's PEP section (peptide-level quantification in
 * the 1.0 proteomics dialect) and by mzTab-M's SMF / SME sections
 * (small-molecule feature + evidence in the 2.0.0-M metabolomics
 * dialect).</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.feature.Feature</code><br/>
 * Java: <code>global.thalion.ttio.Feature</code></p>
 */
@interface TTIOFeature : NSObject <NSCopying>

/** Identifier unique within the file. */
@property (nonatomic, readonly, copy) NSString *featureId;

/** Acquisition-run name. */
@property (nonatomic, readonly, copy) NSString *runName;

/** Identified entity — peptide sequence, CHEBI id, or formula. */
@property (nonatomic, readonly, copy) NSString *chemicalEntity;

/** Apex retention time in seconds. */
@property (nonatomic, readonly) double retentionTimeSeconds;

/** Experimental precursor m/z. */
@property (nonatomic, readonly) double expMassToCharge;

/** Precursor charge state. */
@property (nonatomic, readonly) NSInteger charge;

/** Adduct ion identifier (e.g. <code>@"[M+H]1+"</code>); empty for
 *  peptides. */
@property (nonatomic, readonly, copy) NSString *adductIon;

/** Sample-label to abundance mapping. */
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSNumber *> *abundances;

/** References to supporting evidence rows. */
@property (nonatomic, readonly, copy) NSArray<NSString *> *evidenceRefs;

/**
 * Designated initialiser.
 *
 * @param featureId      Unique identifier.
 * @param runName        Acquisition-run name.
 * @param chemicalEntity Identified entity.
 * @param rtSeconds      Apex retention time.
 * @param mz             Experimental precursor m/z.
 * @param charge         Precursor charge.
 * @param adductIon      Optional adduct ion identifier.
 * @param abundances     Optional per-sample abundances.
 * @param evidenceRefs   Optional evidence references.
 * @return An initialised feature.
 */
- (instancetype)initWithFeatureId:(NSString *)featureId
                          runName:(NSString *)runName
                   chemicalEntity:(NSString *)chemicalEntity
             retentionTimeSeconds:(double)rtSeconds
                  expMassToCharge:(double)mz
                           charge:(NSInteger)charge
                        adductIon:(nullable NSString *)adductIon
                       abundances:(nullable NSDictionary<NSString *, NSNumber *> *)abundances
                     evidenceRefs:(nullable NSArray<NSString *> *)evidenceRefs;

/**
 * Minimal convenience factory; numeric and container fields default
 * to zero / empty.
 */
+ (instancetype)featureWithId:(NSString *)featureId
                      runName:(NSString *)runName
               chemicalEntity:(NSString *)chemicalEntity;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_FEATURE_H */
