/*
 * TTIOReferenceImport.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOReferenceImport
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Genomics/TTIOReferenceImport.h
 *
 * Reference-FASTA value class. Implements the cross-language byte-
 * exact MD5 (sorted by chromosome name; CommonCrypto's CC_MD5 not
 * available on GNUstep, so we use OpenSSL's EVP_MD_CTX which is
 * already a libTTIO link dependency).
 *
 * Licensed under the Apache License, Version 2.0.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOReferenceImport.h"
#import <openssl/evp.h>
#import <openssl/md5.h>


@implementation TTIOReferenceImport

- (instancetype)initWithUri:(NSString *)uri
                chromosomes:(NSArray<NSString *> *)chromosomes
                  sequences:(NSArray<NSData *> *)sequences
                        md5:(NSData *)md5
{
    self = [super init];
    if (!self) return nil;
    if (chromosomes.count != sequences.count) {
        [NSException raise:NSInvalidArgumentException
                    format:@"chromosomes / sequences length mismatch: "
                           @"%lu vs %lu",
                            (unsigned long)chromosomes.count,
                            (unsigned long)sequences.count];
    }
    _uri = [uri copy];
    _chromosomes = [chromosomes copy];
    _sequences = [sequences copy];
    if (md5 != nil) {
        if (md5.length != 16) {
            [NSException raise:NSInvalidArgumentException
                        format:@"md5 must be 16 bytes, got %lu",
                                (unsigned long)md5.length];
        }
        _md5 = [md5 copy];
    } else {
        _md5 = [[self class] computeMd5WithChromosomes:chromosomes
                                             sequences:sequences];
    }
    return self;
}

- (instancetype)initWithUri:(NSString *)uri
                chromosomes:(NSArray<NSString *> *)chromosomes
                  sequences:(NSArray<NSData *> *)sequences
{
    return [self initWithUri:uri chromosomes:chromosomes
                   sequences:sequences md5:nil];
}

+ (NSData *)computeMd5WithChromosomes:(NSArray<NSString *> *)chromosomes
                            sequences:(NSArray<NSData *> *)sequences
{
    if (chromosomes.count != sequences.count) {
        [NSException raise:NSInvalidArgumentException
                    format:@"chromosomes / sequences length mismatch"];
    }
    // Build (name -> seq) index then sort names.
    NSMutableDictionary<NSString *, NSData *> *byName =
        [NSMutableDictionary dictionaryWithCapacity:chromosomes.count];
    for (NSUInteger i = 0; i < chromosomes.count; i++) {
        byName[chromosomes[i]] = sequences[i];
    }
    NSArray<NSString *> *sorted =
        [byName.allKeys sortedArrayUsingSelector:@selector(compare:)];

    MD5_CTX ctx;
    MD5_Init(&ctx);
    for (NSString *name in sorted) {
        NSData *utf8 = [name dataUsingEncoding:NSUTF8StringEncoding];
        MD5_Update(&ctx, utf8.bytes, utf8.length);
        unsigned char lf = 0x0A;
        MD5_Update(&ctx, &lf, 1);
        NSData *seq = byName[name];
        MD5_Update(&ctx, seq.bytes, seq.length);
        MD5_Update(&ctx, &lf, 1);
    }
    unsigned char digest[16];
    MD5_Final(digest, &ctx);
    return [NSData dataWithBytes:digest length:16];
}

/** Decode a 32-character lowercase-hex string into a 16-byte
 *  digest. Returns nil for any input that is not exactly 32 hex
 *  digits — the constructor then recomputes the MD5, matching the
 *  Java/Python fallback semantics. */
static NSData *_TTIO_ParseMd5HexLocal(NSString *hex)
{
    if (hex == nil || hex.length != 32) return nil;
    NSData *ascii = [hex dataUsingEncoding:NSASCIIStringEncoding];
    if (ascii == nil || ascii.length != 32) return nil;
    const uint8_t *src = (const uint8_t *)ascii.bytes;
    uint8_t out[16];
    for (NSUInteger i = 0; i < 16; i++) {
        int hi = -1, lo = -1;
        uint8_t a = src[i * 2];
        uint8_t b = src[i * 2 + 1];
        if (a >= '0' && a <= '9') hi = a - '0';
        else if (a >= 'a' && a <= 'f') hi = 10 + (a - 'a');
        else if (a >= 'A' && a <= 'F') hi = 10 + (a - 'A');
        if (b >= '0' && b <= '9') lo = b - '0';
        else if (b >= 'a' && b <= 'f') lo = 10 + (b - 'a');
        else if (b >= 'A' && b <= 'F') lo = 10 + (b - 'A');
        if (hi < 0 || lo < 0) return nil;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return [NSData dataWithBytes:out length:16];
}

+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)refGroup
{
    if (refGroup == nil) return nil;

    // URI: prefer @reference_uri, fall back to the group's leaf name.
    NSString *uri = nil;
    if ([refGroup hasAttributeNamed:@"reference_uri"]) {
        id v = [refGroup attributeValueForName:@"reference_uri" error:NULL];
        if ([v isKindOfClass:[NSString class]]) {
            uri = (NSString *)v;
        }
    }
    if (uri == nil) {
        uri = [refGroup name] ?: @"";
    }

    // MD5: preserve verbatim from @md5 (lowercase hex) when present,
    // so the read-back instance carries the same digest bytes as the
    // writer used. Missing / malformed → constructor recomputes.
    NSData *md5 = nil;
    if ([refGroup hasAttributeNamed:@"md5"]) {
        id v = [refGroup attributeValueForName:@"md5" error:NULL];
        if ([v isKindOfClass:[NSString class]]) {
            md5 = _TTIO_ParseMd5HexLocal((NSString *)v);
        }
    }

    NSMutableArray<NSString *> *chromNames = [NSMutableArray array];
    NSMutableArray<NSData *> *seqs = [NSMutableArray array];
    if ([refGroup hasChildNamed:@"chromosomes"]) {
        id<TTIOStorageGroup> chromsGrp =
            [refGroup openGroupNamed:@"chromosomes" error:NULL];
        if (chromsGrp == nil) return nil;
        for (NSString *cname in [chromsGrp childNames]) {
            id<TTIOStorageGroup> chromGrp =
                [chromsGrp openGroupNamed:cname error:NULL];
            if (chromGrp == nil) continue;
            id<TTIOStorageDataset> ds =
                [chromGrp openDatasetNamed:@"data" error:NULL];
            if (ds == nil) continue;
            id raw = [ds readAll:NULL];
            if (![raw isKindOfClass:[NSData class]]) continue;
            [chromNames addObject:cname];
            [seqs addObject:(NSData *)raw];
        }
    }

    return [[self alloc] initWithUri:uri
                         chromosomes:chromNames
                           sequences:seqs
                                 md5:md5];
}

- (NSUInteger)totalBases
{
    NSUInteger n = 0;
    for (NSData *s in _sequences) {
        n += s.length;
    }
    return n;
}

- (NSData *)chromosomeNamed:(NSString *)name
{
    NSUInteger idx = [_chromosomes indexOfObject:name];
    if (idx == NSNotFound) return nil;
    return _sequences[idx];
}

- (NSString *)md5Hex
{
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    const unsigned char *bytes = _md5.bytes;
    for (NSUInteger i = 0; i < _md5.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

@end
