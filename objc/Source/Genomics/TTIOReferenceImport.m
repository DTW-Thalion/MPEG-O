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
#import "Dataset/TTIOSpectralDataset.h"
#import "ValueClasses/TTIOEnums.h"
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
    // Build (name -> seq) index then sort names. Sequences are
    // concatenated verbatim (case-preserving, no framing) — matches
    // the REF_DIFF_V2 auto-embed writer (`_TTIO_M93_ReferenceMD5ForRun`)
    // byte-for-byte. Unified in v1.1.0 with the writer's stamp; the
    // previous name+0x0A+seq+0x0A form is gone.
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
        NSData *seq = byName[name];
        MD5_Update(&ctx, seq.bytes, seq.length);
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

- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
                 error:(NSError **)error
{
    return [self writeToDataset:dataset overwrite:NO error:error];
}

- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
             overwrite:(BOOL)overwrite
                 error:(NSError **)error
{
    if (dataset == nil) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2200
                   userInfo:@{NSLocalizedDescriptionKey:
                       @"writeToDataset: dataset must not be nil"}];
        return NO;
    }
    id<TTIOStorageProvider> provider = dataset.provider;
    if (provider == nil || ![provider isOpen]) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2202
                   userInfo:@{NSLocalizedDescriptionKey:
                       @"writeToDataset requires an open dataset with a "
                       @"writable provider"}];
        return NO;
    }
    id<TTIOStorageGroup> root = [provider rootGroupWithError:error];
    if (root == nil) return NO;

    id<TTIOStorageGroup> study = nil;
    if ([root hasChildNamed:@"study"]) {
        study = [root openGroupNamed:@"study" error:error];
    } else {
        study = [root createGroupNamed:@"study" error:error];
    }
    if (study == nil) return NO;

    id<TTIOStorageGroup> refsGrp = nil;
    if ([study hasChildNamed:@"references"]) {
        refsGrp = [study openGroupNamed:@"references" error:error];
    } else {
        refsGrp = [study createGroupNamed:@"references" error:error];
    }
    if (refsGrp == nil) return NO;

    if ([refsGrp hasChildNamed:_uri]) {
        if (!overwrite) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2201
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"reference '%@' already embedded at "
                                @"/study/references/%@; pass overwrite=YES "
                                @"to replace.", _uri, _uri]}];
            return NO;
        }
        if (![refsGrp deleteChildNamed:_uri error:error]) return NO;
    }

    id<TTIOStorageGroup> refGrp =
        [refsGrp createGroupNamed:_uri error:error];
    if (refGrp == nil) return NO;

    if (![refGrp setAttributeValue:[self md5Hex]
                           forName:@"md5"
                             error:error]) return NO;
    if (![refGrp setAttributeValue:_uri
                           forName:@"reference_uri"
                             error:error]) return NO;

    id<TTIOStorageGroup> chromsGrp =
        [refGrp createGroupNamed:@"chromosomes" error:error];
    if (chromsGrp == nil) return NO;

    // Build (name -> seq) map and sort by name so the on-disk child
    // order matches the canonical embed-helper writer byte-for-byte.
    NSMutableDictionary<NSString *, NSData *> *byName =
        [NSMutableDictionary dictionaryWithCapacity:_chromosomes.count];
    for (NSUInteger i = 0; i < _chromosomes.count; i++) {
        byName[_chromosomes[i]] = _sequences[i];
    }
    NSArray<NSString *> *sortedNames =
        [byName.allKeys sortedArrayUsingSelector:@selector(compare:)];

    for (NSString *cname in sortedNames) {
        NSData *seq = byName[cname];
        id<TTIOStorageGroup> cg =
            [chromsGrp createGroupNamed:cname error:error];
        if (cg == nil) return NO;
        if (![cg setAttributeValue:@((int64_t)seq.length)
                           forName:@"length"
                             error:error]) return NO;
        id<TTIOStorageDataset> ds =
            [cg createDatasetNamed:@"data"
                          precision:TTIOPrecisionUInt8
                             length:seq.length
                          chunkSize:65536
                        compression:TTIOCompressionZlib
                   compressionLevel:6
                              error:error];
        if (ds == nil) return NO;
        if (![ds writeAll:seq error:error]) return NO;
    }
    return YES;
}

@end
