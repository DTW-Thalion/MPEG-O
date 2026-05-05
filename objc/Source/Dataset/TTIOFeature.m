/*
 * TTIOFeature.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOFeature
 * Inherits From: NSObject
 * Conforms To:   NSCopying
 * Declared In:   Dataset/TTIOFeature.h
 *
 * Feature-level value object (peak detected in one run with
 * retention time, m/z, charge, per-sample abundances) — the row
 * type required by mzTab PEP and mzTab-M SMF/SME sections.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOFeature.h"

@implementation TTIOFeature

- (instancetype)initWithFeatureId:(NSString *)featureId
                          runName:(NSString *)runName
                   chemicalEntity:(NSString *)chemicalEntity
             retentionTimeSeconds:(double)rtSeconds
                  expMassToCharge:(double)mz
                           charge:(NSInteger)charge
                        adductIon:(NSString *)adductIon
                       abundances:(NSDictionary<NSString *, NSNumber *> *)abundances
                     evidenceRefs:(NSArray<NSString *> *)evidenceRefs
{
    self = [super init];
    if (self) {
        _featureId = [featureId copy] ?: @"";
        _runName = [runName copy] ?: @"";
        _chemicalEntity = [chemicalEntity copy] ?: @"";
        _retentionTimeSeconds = rtSeconds;
        _expMassToCharge = mz;
        _charge = charge;
        _adductIon = [adductIon copy] ?: @"";
        _abundances = [abundances copy] ?: @{};
        _evidenceRefs = [evidenceRefs copy] ?: @[];
    }
    return self;
}

+ (instancetype)featureWithId:(NSString *)featureId
                      runName:(NSString *)runName
               chemicalEntity:(NSString *)chemicalEntity
{
    return [[self alloc] initWithFeatureId:featureId
                                   runName:runName
                            chemicalEntity:chemicalEntity
                      retentionTimeSeconds:0.0
                           expMassToCharge:0.0
                                    charge:0
                                 adductIon:@""
                                abundances:@{}
                              evidenceRefs:@[]];
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOFeature class]]) return NO;
    TTIOFeature *o = (TTIOFeature *)other;
    return [_featureId isEqualToString:o.featureId]
        && [_runName isEqualToString:o.runName]
        && [_chemicalEntity isEqualToString:o.chemicalEntity]
        && _retentionTimeSeconds == o.retentionTimeSeconds
        && _expMassToCharge == o.expMassToCharge
        && _charge == o.charge
        && [_adductIon isEqualToString:o.adductIon]
        && [_abundances isEqualToDictionary:o.abundances]
        && [_evidenceRefs isEqualToArray:o.evidenceRefs];
}

- (NSUInteger)hash
{
    return [_featureId hash] ^ [_chemicalEntity hash] ^ (NSUInteger)_charge;
}

@end
