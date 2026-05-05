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
