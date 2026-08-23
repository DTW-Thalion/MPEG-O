/*
 * TTIOSample.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOSample
 * Inherits From: NSObject
 * Conforms To:   NSCopying
 * Declared In:   Dataset/TTIOSample.h
 *
 * Biological / material Sample first-class entity. Stage 6 of
 * transport-spec v0.11 (Deferral 2).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOSample.h"
#import "Core/TTIOPortability.h"

@implementation TTIOSample

- (instancetype)initWithSampleId:(NSString *)sampleId
               subjectExternalId:(NSString *)subjectExternalId
                      sampleKind:(NSString *)sampleKind
                     collectedAt:(int64_t)collectedAt
                      attributes:(NSDictionary<NSString *, NSString *> *)attributes
{
    if (sampleId == nil || sampleId.length == 0) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIOSample.sampleId must be non-empty"];
    }
    if ([sampleId rangeOfString:@"/"].location != NSNotFound) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIOSample.sampleId may not contain '/': %@",
                           sampleId];
    }
    self = [super init];
    if (self) {
        _sampleId          = [sampleId copy];
        _subjectExternalId = [(subjectExternalId ?: @"") copy];
        _sampleKind        = [(sampleKind ?: @"") copy];
        _collectedAt       = collectedAt;
        _attributes        = [(attributes ?: @{}) copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (NSString *)attributesJson
{
    // TTIOSortedKeysJSON gives sort-keys + no-whitespace output that
    // is byte-equivalent to Python's `json.dumps(sort_keys=True,
    // separators=(",", ":"))` and Java's TreeMap-walk emit on every
    // Foundation we support, including GNUstep-base 1.31.1 where
    // NSJSONWritingSortedKeys is a no-op.
    return TTIOSortedKeysJSON(_attributes);
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOSample class]]) return NO;
    TTIOSample *o = (TTIOSample *)other;
    return [_sampleId          isEqualToString:o.sampleId]
        && [_subjectExternalId isEqualToString:o.subjectExternalId]
        && [_sampleKind        isEqualToString:o.sampleKind]
        &&  _collectedAt       == o.collectedAt
        && [_attributes        isEqualToDictionary:o.attributes];
}

- (NSUInteger)hash
{
    return [_sampleId hash] ^ (NSUInteger)_collectedAt;
}

@end
