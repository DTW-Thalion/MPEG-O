/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "Genomics/TTIOLazyReference.h"
#import "HDF5/TTIOHDF5Errors.h"

@interface TTIOFaiEntry : NSObject
@property (nonatomic) unsigned long long length;
@property (nonatomic) unsigned long long offset;
@property (nonatomic) unsigned long long lineBases;
@property (nonatomic) unsigned long long lineWidth;
@end
@implementation TTIOFaiEntry
@end

@implementation TTIOLazyReference {
    NSString *_path;
    NSMutableArray<NSString *> *_names;
    NSMutableDictionary<NSString *, TTIOFaiEntry *> *_entries;
    NSMutableArray<NSString *> *_lru;
    NSMutableDictionary<NSString *, NSData *> *_cache;
    NSUInteger _cacheN;
}

/* NSDictionary's -init routes here; the storage is ours. */
- (instancetype)initWithObjects:(const id [])objects
                        forKeys:(const id<NSCopying> [])keys
                          count:(NSUInteger)cnt
{
    (void)objects; (void)keys; (void)cnt;
    return self;
}

- (instancetype)initWithFastaPath:(NSString *)path error:(NSError **)error
{
    return [self initWithFastaPath:path cacheChroms:2 error:error];
}

- (instancetype)initWithFastaPath:(NSString *)path
                      cacheChroms:(NSUInteger)cacheChroms
                            error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;
    _path = [path copy];
    _names = [NSMutableArray array];
    _entries = [NSMutableDictionary dictionary];
    _lru = [NSMutableArray array];
    _cache = [NSMutableDictionary dictionary];
    _cacheN = MAX(cacheChroms, (NSUInteger)1);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        if (error) *error = TTIOMakeError(TTIOErrorFileNotFound, @"reference FASTA not found: %@", path);
        return nil;
    }
    NSString *fai = [path stringByAppendingString:@".fai"];
    NSString *text = nil;
    if ([fm fileExistsAtPath:fai]) {
        text = [NSString stringWithContentsOfFile:fai encoding:NSUTF8StringEncoding error:error];
        if (!text) return nil;
    } else {
        text = [self _buildIndexText:error];
        if (!text) return nil;
        [text writeToFile:fai atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if (f.count < 5) continue;
        TTIOFaiEntry *e = [TTIOFaiEntry new];
        e.length = strtoull([f[1] UTF8String], NULL, 10);
        e.offset = strtoull([f[2] UTF8String], NULL, 10);
        e.lineBases = strtoull([f[3] UTF8String], NULL, 10);
        e.lineWidth = strtoull([f[4] UTF8String], NULL, 10);
        if (_entries[f[0]] == nil) [_names addObject:f[0]];
        _entries[f[0]] = e;
    }
    return self;
}

/* Scan the FASTA once and produce the samtools faidx text: name,
 * length, offset of the first base, bases per line, bytes per line. */
- (NSString *)_buildIndexText:(NSError **)error
{
    NSData *raw = [NSData dataWithContentsOfFile:_path options:NSDataReadingMappedIfSafe error:error];
    if (!raw) return nil;
    const uint8_t *b = (const uint8_t *)raw.bytes;
    NSUInteger n = raw.length;
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0;
    while (i < n) {
        if (b[i] != '>') {
            while (i < n && b[i] != '\n') i++;
            i++;
            continue;
        }
        NSUInteger hs = i + 1, he = hs;
        while (he < n && b[he] != '\n') he++;
        NSUInteger ne = hs;
        while (ne < he && b[ne] != ' ' && b[ne] != '\t' && b[ne] != '\r') ne++;
        NSString *name = [[NSString alloc] initWithBytes:b + hs length:ne - hs encoding:NSUTF8StringEncoding] ?: @"";
        NSUInteger seqStart = he + 1;
        unsigned long long length = 0, lineBases = 0, lineWidth = 0;
        NSUInteger p = seqStart;
        BOOL first = YES;
        while (p < n && b[p] != '>') {
            NSUInteger le = p;
            while (le < n && b[le] != '\n') le++;
            NSUInteger bases = le - p;
            if (bases > 0 && b[le - 1] == '\r') bases--;
            NSUInteger width = (le < n ? le + 1 : le) - p;
            if (first) { lineBases = bases; lineWidth = width; first = NO; }
            length += bases;
            p = le + 1;
        }
        [out appendFormat:@"%@\t%llu\t%llu\t%llu\t%llu\n", name, length,
             (unsigned long long)seqStart, lineBases, lineWidth];
        i = p;
    }
    return out;
}

- (NSString *)fastaPath { return _path; }
- (NSArray<NSString *> *)chromosomeNames { return [_names copy]; }

- (NSUInteger)lengthOf:(NSString *)name
{
    TTIOFaiEntry *e = _entries[name];
    return e ? (NSUInteger)e.length : NSNotFound;
}

// ── NSDictionary primitives ──────────────────────────────────────

- (NSUInteger)count { return _entries.count; }

- (NSEnumerator *)keyEnumerator { return [[_names copy] objectEnumerator]; }

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(__unsafe_unretained id [])buffer
                                    count:(NSUInteger)len
{
    return [_names countByEnumeratingWithState:state objects:buffer count:len];
}

- (NSData *)objectForKey:(NSString *)name
{
    if (![name isKindOfClass:[NSString class]]) return nil;
    TTIOFaiEntry *e = _entries[name];
    if (!e) return nil;
    NSData *cached = _cache[name];
    if (cached) {
        [_lru removeObject:name];
        [_lru addObject:name];
        return cached;
    }
    NSData *seq = [self _load:e name:name];
    if (!seq) return nil;
    _cache[name] = seq;
    [_lru addObject:name];
    while (_lru.count > _cacheN) {
        NSString *old = _lru[0];
        [_lru removeObjectAtIndex:0];
        [_cache removeObjectForKey:old];
    }
    return seq;
}

- (NSData *)_load:(TTIOFaiEntry *)e name:(NSString *)name
{
    if (e.length == 0) return [NSData data];
    if (e.lineBases == 0) return nil;
    unsigned long long nFull = e.length / e.lineBases;
    unsigned long long rest = e.length - nFull * e.lineBases;
    unsigned long long nBytes = nFull * e.lineWidth + rest;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:_path];
    if (!fh) return nil;
    [fh seekToFileOffset:e.offset];
    NSData *raw = [fh readDataOfLength:(NSUInteger)nBytes];
    [fh closeFile];
    NSMutableData *seq = [NSMutableData dataWithCapacity:(NSUInteger)e.length];
    const uint8_t *b = (const uint8_t *)raw.bytes;
    NSUInteger n = raw.length, runStart = 0;
    for (NSUInteger i = 0; i < n; i++) {
        if (b[i] == '\n' || b[i] == '\r') {
            if (i > runStart) [seq appendBytes:b + runStart length:i - runStart];
            runStart = i + 1;
        }
    }
    if (n > runStart) [seq appendBytes:b + runStart length:n - runStart];
    if (seq.length != e.length) return nil;
    return seq;
}

- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    return self;
}

@end
