/*
 * TTIOQuantification.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOQuantification
 * Inherits From: NSObject
 * Conforms To:   NSCopying
 * Declared In:   Dataset/TTIOQuantification.h
 *
 * Per-sample abundance value with optional normalisation method.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOQuantification.h"

@implementation TTIOQuantification

- (instancetype)initWithChemicalEntity:(NSString *)entity
                             sampleRef:(NSString *)sampleRef
                             abundance:(double)abundance
                   normalizationMethod:(NSString *)method
{
    return [self initWithChemicalEntity:entity
                              sampleRef:sampleRef
                              abundance:abundance
                    normalizationMethod:method
                                   unit:@""];
}

- (instancetype)initWithChemicalEntity:(NSString *)entity
                             sampleRef:(NSString *)sampleRef
                             abundance:(double)abundance
                   normalizationMethod:(NSString *)method
                                  unit:(NSString *)unit
{
    self = [super init];
    if (self) {
        _chemicalEntity      = [entity copy];
        _sampleRef           = [sampleRef copy];
        _abundance           = abundance;
        _normalizationMethod = [method copy];
        _unit                = unit ? [unit copy] : @"";
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (NSDictionary *)asPlist
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"chemical_entity"] = _chemicalEntity ?: @"";
    d[@"sample_ref"]      = _sampleRef ?: @"";
    d[@"abundance"]       = @(_abundance);
    if (_normalizationMethod) d[@"normalization_method"] = _normalizationMethod;
    if (_unit && _unit.length > 0) d[@"unit"] = _unit;
    return d;
}

+ (instancetype)fromPlist:(NSDictionary *)plist
{
    NSString *unit = plist[@"unit"];
    return [[self alloc] initWithChemicalEntity:plist[@"chemical_entity"]
                                       sampleRef:plist[@"sample_ref"]
                                       abundance:[plist[@"abundance"] doubleValue]
                             normalizationMethod:plist[@"normalization_method"]
                                            unit:(unit ?: @"")];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOQuantification class]]) return NO;
    TTIOQuantification *o = (TTIOQuantification *)other;
    if (![_chemicalEntity isEqualToString:o.chemicalEntity]) return NO;
    if (![_sampleRef isEqualToString:o.sampleRef]) return NO;
    if (_abundance != o.abundance) return NO;
    if ((_normalizationMethod || o.normalizationMethod) &&
        ![_normalizationMethod isEqualToString:o.normalizationMethod]) return NO;
    NSString *u1 = _unit ?: @"";
    NSString *u2 = o.unit ?: @"";
    if (![u1 isEqualToString:u2]) return NO;
    return YES;
}

- (NSUInteger)hash { return [_chemicalEntity hash] ^ [_sampleRef hash]; }

@end
