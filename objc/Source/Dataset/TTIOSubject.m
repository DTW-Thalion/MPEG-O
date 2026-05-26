/*
 * TTIOSubject.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOSubject
 * Inherits From: NSObject
 * Conforms To:   NSCopying
 * Declared In:   Dataset/TTIOSubject.h
 *
 * Study Subject (donor / patient / animal / object) first-class
 * entity. Stage 6 of transport-spec v0.11 (Deferral 2). See design
 * spec docs/superpowers/specs/2026-05-26-subjects-samples-design.md.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOSubject.h"
#import "Core/TTIOPortability.h"

@implementation TTIOSubject

- (instancetype)initWithExternalId:(NSString *)externalId
                            project:(NSString *)project
                                sex:(NSString *)sex
                          birthYear:(int64_t)birthYear
                         attributes:(NSDictionary<NSString *, NSString *> *)attributes
{
    if (externalId == nil || externalId.length == 0) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIOSubject.externalId must be non-empty"];
    }
    if ([externalId rangeOfString:@"/"].location != NSNotFound) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIOSubject.externalId may not contain '/': %@",
                           externalId];
    }
    self = [super init];
    if (self) {
        _externalId = [externalId copy];
        _project    = [(project ?: @"") copy];
        _sex        = [(sex ?: @"") copy];
        _birthYear  = birthYear;
        _attributes = [(attributes ?: @{}) copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (NSString *)attributesJson
{
    if (_attributes.count == 0) return @"{}";
    NSError *err = nil;
    NSData *data = [NSJSONSerialization
        dataWithJSONObject:_attributes
                   options:TTIO_JSON_SORTED_KEYS
                     error:&err];
    if (data == nil) return @"{}";
    NSString *s = [[NSString alloc] initWithData:data
                                         encoding:NSUTF8StringEncoding];
    return s ?: @"{}";
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOSubject class]]) return NO;
    TTIOSubject *o = (TTIOSubject *)other;
    return [_externalId isEqualToString:o.externalId]
        && [_project    isEqualToString:o.project]
        && [_sex        isEqualToString:o.sex]
        && _birthYear  == o.birthYear
        && [_attributes isEqualToDictionary:o.attributes];
}

- (NSUInteger)hash
{
    return [_externalId hash] ^ (NSUInteger)_birthYear;
}

@end
