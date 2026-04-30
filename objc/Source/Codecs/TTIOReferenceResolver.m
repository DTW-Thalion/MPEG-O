/*
 * TTIOReferenceResolver.m — reference chromosome resolution for M93 REF_DIFF.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIOReferenceResolver.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"

#include <openssl/md5.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

NSString * const TTIORefMissingErrorDomain = @"TTIORefMissingError";

static void rr_set_error(NSError * _Nullable * _Nullable outError,
                          NSInteger code,
                          NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void rr_set_error(NSError * _Nullable * _Nullable outError,
                          NSInteger code,
                          NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:TTIORefMissingErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSString *hex16(NSData *bytes)
{
    if (bytes.length != 16) return @"";
    const uint8_t *p = (const uint8_t *)bytes.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

static NSData *hexToData(NSString *hex)
{
    NSUInteger n = hex.length;
    if (n != 32) return nil;
    NSMutableData *d = [NSMutableData dataWithLength:16];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    const char *src = [hex UTF8String];
    for (int i = 0; i < 16; i++) {
        unsigned int v = 0;
        if (sscanf(src + i*2, "%2x", &v) != 1) return nil;
        p[i] = (uint8_t)v;
    }
    return d;
}

@implementation TTIOReferenceResolver {
    TTIOHDF5Group *_root;
    NSString *_external;
}

- (instancetype)initWithRootGroup:(TTIOHDF5Group *)rootGroup
          externalReferencePath:(nullable NSString *)externalReferencePath
{
    self = [super init];
    if (self) {
        _root = rootGroup;
        if (externalReferencePath.length > 0) {
            _external = [externalReferencePath copy];
        } else {
            const char *envP = getenv("REF_PATH");
            _external = (envP && *envP) ? [NSString stringWithUTF8String:envP] : nil;
        }
    }
    return self;
}

// ── Embedded reference lookup ──────────────────────────────────────

- (nullable NSData *)readEmbeddedURI:(NSString *)uri
                          chromosome:(NSString *)chromosome
                         expectedMD5:(NSData *)expectedMD5
                               error:(NSError **)error
{
    if (!_root) return nil;
    NSError *e = nil;
    if (![_root hasChildNamed:@"study"]) return nil;
    TTIOHDF5Group *study = [_root openGroupNamed:@"study" error:&e];
    if (!study) return nil;
    if (![study hasChildNamed:@"references"]) return nil;
    TTIOHDF5Group *refsG = [study openGroupNamed:@"references" error:&e];
    if (!refsG) return nil;
    if (![refsG hasChildNamed:uri]) return nil;
    TTIOHDF5Group *refG = [refsG openGroupNamed:uri error:&e];
    if (!refG) return nil;

    NSString *embeddedHex = [refG stringAttributeNamed:@"md5" error:&e];
    NSData *embeddedMD5 = embeddedHex.length == 32 ? hexToData(embeddedHex) : nil;
    if (!embeddedMD5 || ![embeddedMD5 isEqualToData:expectedMD5]) {
        rr_set_error(error, 1,
            @"MD5 mismatch for embedded reference %@: expected %@, got %@",
            uri, hex16(expectedMD5), embeddedHex ?: @"<missing>");
        return nil;
    }
    if (![refG hasChildNamed:@"chromosomes"]) {
        rr_set_error(error, 2,
            @"chromosome %@ not embedded in reference %@ (no chromosomes group)",
            chromosome, uri);
        return nil;
    }
    TTIOHDF5Group *chromsG = [refG openGroupNamed:@"chromosomes" error:&e];
    if (!chromsG) return nil;
    if (![chromsG hasChildNamed:chromosome]) {
        rr_set_error(error, 3,
            @"chromosome %@ not embedded in reference %@", chromosome, uri);
        return nil;
    }
    TTIOHDF5Group *chromG = [chromsG openGroupNamed:chromosome error:&e];
    if (!chromG) return nil;
    TTIOHDF5Dataset *ds = [chromG openDatasetNamed:@"data" error:&e];
    if (!ds) return nil;
    NSData *bytes = [ds readDataWithError:&e];
    if (!bytes) {
        rr_set_error(error, 4,
            @"chromosome %@ data dataset read failed: %@", chromosome,
            e.localizedDescription);
        return nil;
    }
    return bytes;
}

// ── External FASTA reading ─────────────────────────────────────────

static NSData *read_fasta_chrom(NSString *path, NSString *chrom)
{
    NSData *all = [NSData dataWithContentsOfFile:path];
    if (!all) return nil;
    NSData *targetData = [chrom dataUsingEncoding:NSASCIIStringEncoding];
    if (!targetData) return nil;
    const uint8_t *p = (const uint8_t *)all.bytes;
    NSUInteger n = all.length;
    NSMutableData *out = [NSMutableData data];
    BOOL inTarget = NO;
    NSUInteger i = 0;
    while (i < n) {
        // Read one line.
        NSUInteger lineStart = i;
        while (i < n && p[i] != '\n') i++;
        NSUInteger lineEnd = i;
        if (i < n) i++;  // consume \n
        if (lineEnd > lineStart && p[lineStart] == '>') {
            if (inTarget) return out;
            // Match header up to first whitespace.
            NSUInteger hs = lineStart + 1;
            NSUInteger he = hs;
            while (he < lineEnd && p[he] != ' ' && p[he] != '\t' && p[he] != '\r') he++;
            NSData *hdr = [NSData dataWithBytes:p + hs length:he - hs];
            inTarget = [hdr isEqualToData:targetData];
            [out setLength:0];
        } else if (inTarget) {
            // Strip trailing \r and whitespace.
            NSUInteger e2 = lineEnd;
            while (e2 > lineStart && (p[e2 - 1] == '\r' || p[e2 - 1] == ' ' || p[e2 - 1] == '\t')) e2--;
            if (e2 > lineStart) [out appendBytes:p + lineStart length:e2 - lineStart];
        }
    }
    if (inTarget) return out;
    return nil;
}

- (nullable NSData *)readExternalChromosome:(NSString *)chromosome
                                expectedMD5:(NSData *)expectedMD5
                                      error:(NSError **)error
{
    if (!_external) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_external]) return nil;
    NSData *seq = read_fasta_chrom(_external, chromosome);
    if (!seq) return nil;
    uint8_t digest[16];
    MD5_CTX c; MD5_Init(&c); MD5_Update(&c, seq.bytes, seq.length); MD5_Final(digest, &c);
    NSData *actual = [NSData dataWithBytes:digest length:16];
    if (![actual isEqualToData:expectedMD5]) {
        rr_set_error(error, 5,
            @"MD5 mismatch for external reference at %@: expected %@, got %@",
            _external, hex16(expectedMD5), hex16(actual));
        return nil;
    }
    return seq;
}

// ── Public resolve ─────────────────────────────────────────────────

- (nullable NSData *)resolveURI:(NSString *)uri
                    expectedMD5:(NSData *)expectedMD5
                     chromosome:(NSString *)chromosome
                          error:(NSError * _Nullable *)error
{
    NSError *embedErr = nil;
    NSData *seq = [self readEmbeddedURI:uri
                              chromosome:chromosome
                             expectedMD5:expectedMD5
                                   error:&embedErr];
    if (seq) return seq;
    if (embedErr) {
        // Embedded was found but failed (MD5 mismatch / chrom missing); do
        // NOT silently fall back — surface the specific failure to caller.
        if (error) *error = embedErr;
        return nil;
    }

    NSError *extErr = nil;
    NSData *ext = [self readExternalChromosome:chromosome
                                   expectedMD5:expectedMD5
                                         error:&extErr];
    if (ext) return ext;
    if (extErr) {
        if (error) *error = extErr;
        return nil;
    }

    rr_set_error(error, 6,
        @"reference %@ (chromosome %@) not found in /study/references/ "
        @"and not resolvable via REF_PATH (%s). Provide an external "
        @"reference path or set REF_PATH.",
        uri, chromosome, getenv("REF_PATH") ?: "<unset>");
    return nil;
}

@end
