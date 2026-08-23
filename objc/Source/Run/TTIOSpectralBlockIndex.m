/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "Run/TTIOSpectralBlockIndex.h"
#import "Providers/TTIOCompoundField.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOSpectralBlockIndex {
    NSUInteger _n;
    NSArray<NSString *> *_channels;
    unsigned long long *_valueStart;
    NSUInteger *_values;
    NSMutableDictionary<NSString *, NSMutableData *> *_off;
    NSMutableDictionary<NSString *, NSMutableData *> *_len;
    NSMutableDictionary<NSString *, NSMutableData *> *_codec;
}

static BOOL ttioSpecRowNum(NSDictionary *row, NSString *key,
                           unsigned long long *out, NSError **error)
{
    id v = row[key];
    if (v == nil) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"blocks/index: missing column %@", key);
        return NO;
    }
    *out = [v unsignedLongLongValue];
    return YES;
}

/* The channel set is not fixed for a spectral run, so it is recovered
 * from the compound layout: every "<channel>_off" column names one. */
static NSArray<NSString *> *ttioChannelsFromFields(NSArray<TTIOCompoundField *> *fields)
{
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (TTIOCompoundField *f in fields) {
        NSString *n = f.name;
        if ([n hasSuffix:@"_off"]) {
            [out addObject:[n substringToIndex:n.length - 4]];
        }
    }
    return out;
}

+ (instancetype)readFromRunGroup:(id<TTIOStorageGroup>)runGroup error:(NSError **)error
{
    if (![runGroup hasChildNamed:@"blocks"]) return nil;
    id<TTIOStorageGroup> blocks = [runGroup openGroupNamed:@"blocks" error:error];
    if (!blocks) return nil;
    if (![blocks hasChildNamed:@"index"]) return nil;
    id<TTIOStorageDataset> ds = [blocks openDatasetNamed:@"index" error:error];
    if (!ds) return nil;
    NSArray<NSString *> *channels = ttioChannelsFromFields([ds compoundFields]);
    NSArray *rows = [ds readRows:error];
    if (!rows) return nil;
    TTIOSpectralBlockIndex *t = [[TTIOSpectralBlockIndex alloc] init];
    if (![t _loadRows:rows channels:channels error:error]) return nil;
    return t;
}

- (BOOL)_loadRows:(NSArray<NSDictionary *> *)rows
         channels:(NSArray<NSString *> *)channels
            error:(NSError **)error
{
    _n = rows.count;
    _channels = [channels copy];
    NSUInteger slots = MAX(_n, (NSUInteger)1);
    _valueStart = calloc(slots, sizeof(unsigned long long));
    _values = calloc(slots, sizeof(NSUInteger));
    if (!_valueStart || !_values) return NO;
    _off = [NSMutableDictionary dictionary];
    _len = [NSMutableDictionary dictionary];
    _codec = [NSMutableDictionary dictionary];
    for (NSString *ch in _channels) {
        _off[ch] = [NSMutableData dataWithLength:slots * sizeof(unsigned long long)];
        _len[ch] = [NSMutableData dataWithLength:slots * sizeof(unsigned long long)];
        _codec[ch] = [NSMutableData dataWithLength:slots * sizeof(NSUInteger)];
    }
    for (NSUInteger i = 0; i < _n; i++) {
        NSDictionary *r = rows[i];
        unsigned long long v;
        if (!ttioSpecRowNum(r, @"value_start", &v, error)) return NO;
        _valueStart[i] = v;
        if (!ttioSpecRowNum(r, @"n_values", &v, error)) return NO;
        _values[i] = (NSUInteger)v;
        for (NSString *ch in _channels) {
            if (!ttioSpecRowNum(r, [ch stringByAppendingString:@"_off"], &v, error)) return NO;
            ((unsigned long long *)_off[ch].mutableBytes)[i] = v;
            if (!ttioSpecRowNum(r, [ch stringByAppendingString:@"_len"], &v, error)) return NO;
            ((unsigned long long *)_len[ch].mutableBytes)[i] = v;
            id cv = r[[ch stringByAppendingString:@"_codec"]];
            ((NSUInteger *)_codec[ch].mutableBytes)[i] =
                cv ? (NSUInteger)[cv unsignedLongLongValue] : 0;
        }
    }
    return YES;
}

- (void)dealloc
{
    free(_valueStart);
    free(_values);
}

- (NSUInteger)count { return _n; }
- (NSArray<NSString *> *)channelNames { return _channels; }

- (unsigned long long)valueCount
{
    if (_n == 0) return 0;
    return _valueStart[_n - 1] + (unsigned long long)_values[_n - 1];
}

- (unsigned long long)valueStartAt:(NSUInteger)block
{
    return block < _n ? _valueStart[block] : 0;
}

- (NSUInteger)valuesAt:(NSUInteger)block
{
    return block < _n ? _values[block] : 0;
}

- (unsigned long long)offsetOf:(NSString *)channel at:(NSUInteger)block
{
    NSMutableData *d = _off[channel];
    if (!d || block >= _n) return 0;
    return ((const unsigned long long *)d.bytes)[block];
}

- (unsigned long long)lengthOf:(NSString *)channel at:(NSUInteger)block
{
    NSMutableData *d = _len[channel];
    if (!d || block >= _n) return 0;
    return ((const unsigned long long *)d.bytes)[block];
}

- (NSUInteger)codecOf:(NSString *)channel at:(NSUInteger)block
{
    NSMutableData *d = _codec[channel];
    if (!d || block >= _n) return 0;
    return ((const NSUInteger *)d.bytes)[block];
}

- (NSUInteger)blockForValue:(unsigned long long)i
{
    if (_n == 0 || i >= self.valueCount) return NSNotFound;
    NSUInteger lo = 0, hi = _n - 1;
    while (lo < hi) {
        NSUInteger mid = (lo + hi + 1) / 2;
        if (_valueStart[mid] <= i) lo = mid; else hi = mid - 1;
    }
    return lo;
}

@end
