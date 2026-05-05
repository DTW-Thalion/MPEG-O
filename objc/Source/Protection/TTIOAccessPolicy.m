/*
 * TTIOAccessPolicy.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOAccessPolicy
 * Inherits From: NSObject
 * Conforms To:   NSCopying
 * Declared In:   Protection/TTIOAccessPolicy.h
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOAccessPolicy.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOAccessPolicy

- (instancetype)initWithPolicy:(NSDictionary *)policy
{
    self = [super init];
    if (self) {
        _policy = [policy copy] ?: @{};
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)writeToFile:(TTIOHDF5File *)file error:(NSError **)error
{
    TTIOHDF5Group *root = [file rootGroup];
    TTIOHDF5Group *prot = nil;
    if ([root hasChildNamed:@"protection"]) {
        prot = [root openGroupNamed:@"protection" error:error];
    } else {
        prot = [root createGroupNamed:@"protection" error:error];
    }
    if (!prot) return NO;

    NSData *json = [NSJSONSerialization dataWithJSONObject:_policy options:0 error:error];
    if (!json) return NO;
    NSString *jstr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    return [prot setStringAttribute:@"access_policies" value:jstr error:error];
}

+ (instancetype)readFromFile:(TTIOHDF5File *)file error:(NSError **)error
{
    TTIOHDF5Group *root = [file rootGroup];
    if (![root hasChildNamed:@"protection"]) {
        if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"no protection group in file");
        return nil;
    }
    TTIOHDF5Group *prot = [root openGroupNamed:@"protection" error:error];
    if (!prot) return nil;
    NSString *jstr = [prot stringAttributeNamed:@"access_policies" error:error];
    if (!jstr) return nil;
    NSData *jdata = [jstr dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *plist = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:error];
    if (!plist) return nil;
    return [[self alloc] initWithPolicy:plist];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOAccessPolicy class]]) return NO;
    return [_policy isEqualToDictionary:[(TTIOAccessPolicy *)other policy]];
}

- (NSUInteger)hash { return [_policy count]; }

@end
