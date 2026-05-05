/*
 * TTIOTransitionList.m
 * TTI-O Objective-C Implementation
 *
 * Classes:       TTIOTransition, TTIOTransitionList
 * Inherits From: NSObject
 * Declared In:   Dataset/TTIOTransitionList.h
 *
 * SRM/MRM transition value class (TTIOTransition) and ordered list
 * container (TTIOTransitionList) persisted as a JSON-encoded
 * attribute under /study/transitions/.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOTransitionList.h"
#import "ValueClasses/TTIOValueRange.h"

@implementation TTIOTransition

- (instancetype)initWithPrecursorMz:(double)precursor
                          productMz:(double)product
                    collisionEnergy:(double)ce
                retentionTimeWindow:(TTIOValueRange *)window
{
    self = [super init];
    if (self) {
        _precursorMz = precursor;
        _productMz   = product;
        _collisionEnergy = ce;
        _retentionTimeWindow = window;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOTransition class]]) return NO;
    TTIOTransition *o = (TTIOTransition *)other;
    if (_precursorMz != o.precursorMz) return NO;
    if (_productMz != o.productMz) return NO;
    if (_collisionEnergy != o.collisionEnergy) return NO;
    if ((_retentionTimeWindow || o.retentionTimeWindow) &&
        ![_retentionTimeWindow isEqual:o.retentionTimeWindow]) return NO;
    return YES;
}

- (NSUInteger)hash { return (NSUInteger)(_precursorMz * 1000) ^ (NSUInteger)(_productMz * 1000); }

@end

@implementation TTIOTransitionList

- (instancetype)initWithTransitions:(NSArray<TTIOTransition *> *)transitions
{
    self = [super init];
    if (self) {
        _transitions = [transitions copy] ?: @[];
    }
    return self;
}

- (NSUInteger)count { return _transitions.count; }
- (TTIOTransition *)transitionAtIndex:(NSUInteger)index { return _transitions[index]; }

- (NSDictionary *)asPlist
{
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:_transitions.count];
    for (TTIOTransition *t in _transitions) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"precursor_mz"]    = @(t.precursorMz);
        d[@"product_mz"]      = @(t.productMz);
        d[@"collision_energy"] = @(t.collisionEnergy);
        if (t.retentionTimeWindow) {
            d[@"rt_window_min"] = @(t.retentionTimeWindow.minimum);
            d[@"rt_window_max"] = @(t.retentionTimeWindow.maximum);
        }
        [arr addObject:d];
    }
    return @{ @"transitions": arr };
}

+ (instancetype)fromPlist:(NSDictionary *)plist
{
    NSArray *arr = plist[@"transitions"];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:arr.count];
    for (NSDictionary *d in arr) {
        TTIOValueRange *w = nil;
        if (d[@"rt_window_min"]) {
            w = [TTIOValueRange rangeWithMinimum:[d[@"rt_window_min"] doubleValue]
                                          maximum:[d[@"rt_window_max"] doubleValue]];
        }
        TTIOTransition *t =
            [[TTIOTransition alloc] initWithPrecursorMz:[d[@"precursor_mz"] doubleValue]
                                              productMz:[d[@"product_mz"] doubleValue]
                                        collisionEnergy:[d[@"collision_energy"] doubleValue]
                                    retentionTimeWindow:w];
        [out addObject:t];
    }
    return [[self alloc] initWithTransitions:out];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOTransitionList class]]) return NO;
    return [_transitions isEqualToArray:[(TTIOTransitionList *)other transitions]];
}

- (NSUInteger)hash { return _transitions.count; }

@end
