/*
 * TTIOReferenceResolver.m — reference chromosome resolution for M93 REF_DIFF.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIOReferenceResolver.h"
#import "Genomics/TTIOPackedReference.h"
#import "Genomics/TTIOLazyReference.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"

#include <openssl/md5.h>
#include <pthread.h>
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
    /* Layout dispatch: data_packed (2-bit + run mask) when present,
       legacy raw data otherwise. */
    BOOL packed = [chromG hasChildNamed:@"data_packed"];
    TTIOHDF5Dataset *ds =
        [chromG openDatasetNamed:(packed ? @"data_packed" : @"data") error:&e];
    if (!ds) return nil;
    NSData *bytes = [ds readDataWithError:&e];
    if (!bytes) {
        rr_set_error(error, 4,
            @"chromosome %@ data dataset read failed: %@", chromosome,
            e.localizedDescription);
        return nil;
    }
    if (packed) {
        NSData *decoded = [TTIOPackedReference decode:bytes error:&e];
        if (!decoded) {
            rr_set_error(error, 4,
                @"chromosome %@ data_packed decode failed: %@", chromosome,
                e.localizedDescription);
            return nil;
        }
        return decoded;
    }
    return bytes;
}

// ── External FASTA reading ─────────────────────────────────────────

/* One TTIOLazyReference (and its reference-set digest) per FASTA path
 * for the process: the .fai index makes a chromosome read O(its
 * length), and the whole-FASTA digest is computed at most once. */
static NSMutableDictionary<NSString *, TTIOLazyReference *> *rr_lazy = nil;
static NSMutableDictionary<NSString *, NSData *> *rr_setMD5 = nil;
static pthread_mutex_t rr_lock = PTHREAD_MUTEX_INITIALIZER;

static NSData *md5_of(NSData *d)
{
    uint8_t digest[16];
    MD5_CTX c; MD5_Init(&c); MD5_Update(&c, d.bytes, d.length); MD5_Final(digest, &c);
    return [NSData dataWithBytes:digest length:16];
}

static NSData *upper_of(NSData *d)
{
    NSMutableData *u = [d mutableCopy];
    uint8_t *p = (uint8_t *)u.mutableBytes;
    for (NSUInteger i = 0; i < u.length; i++) {
        if (p[i] >= 'a' && p[i] <= 'z') p[i] = (uint8_t)(p[i] - 32);
    }
    return u;
}

/* Read the chromosome through the .fai index and check expectedMD5
 * against, in order: the md5 of the chromosome's case-preserved bytes,
 * of its upper-cased bytes (both the pre-1.9 external check, which only
 * ever matched a single-contig FASTA), then the reference-set md5 of
 * the whole FASTA (every chromosome, alphabetic order, case preserved:
 * the digest the writers record). Returns the upper-cased sequence,
 * nil (no error) when the chromosome is not in the FASTA. */
- (nullable NSData *)readExternalChromosome:(NSString *)chromosome
                                expectedMD5:(NSData *)expectedMD5
                                      error:(NSError **)error
{
    if (!_external) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_external]) return nil;
    NSString *key = [_external stringByStandardizingPath];
    pthread_mutex_lock(&rr_lock);
    if (!rr_lazy) { rr_lazy = [NSMutableDictionary new]; rr_setMD5 = [NSMutableDictionary new]; }
    TTIOLazyReference *ref = rr_lazy[key];
    if (!ref) {
        NSError *e = nil;
        ref = [[TTIOLazyReference alloc] initWithFastaPath:key cacheChroms:2 error:&e];
        if (!ref) {
            pthread_mutex_unlock(&rr_lock);
            rr_set_error(error, 5, @"cannot index external reference at %@: %@", _external, e);
            return nil;
        }
        rr_lazy[key] = ref;
    }
    NSData *raw = [ref objectForKey:chromosome];
    if (!raw) { pthread_mutex_unlock(&rr_lock); return nil; }
    NSData *upper = upper_of(raw);
    if ([md5_of(raw) isEqualToData:expectedMD5] || [md5_of(upper) isEqualToData:expectedMD5]) {
        pthread_mutex_unlock(&rr_lock);
        return upper;
    }
    NSData *setMD5 = rr_setMD5[key];
    if (!setMD5) { setMD5 = [ref setMD5]; rr_setMD5[key] = setMD5; }
    pthread_mutex_unlock(&rr_lock);
    if ([setMD5 isEqualToData:expectedMD5]) return upper;
    rr_set_error(error, 5,
        @"MD5 mismatch for external reference at %@: expected %@, got %@ for the whole FASTA and %@ for chromosome %@",
        _external, hex16(expectedMD5), hex16(setMD5), hex16(md5_of(raw)), chromosome);
    return nil;
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
