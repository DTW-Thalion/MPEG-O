/*
 * TTIORefDiffV2.m -- CRAM-style bit-packed sequence diff codec (codec id 14).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIORefDiffV2.h"

#if __has_include(<ttio_rans.h>)
#include <ttio_rans.h>
#define TTIO_HAS_NATIVE_RANS 1
#else
#define TTIO_HAS_NATIVE_RANS 0
#endif

NSString *const TTIORefDiffV2ErrorDomain = @"global.thalion.ttio.RefDiffV2";

#if TTIO_HAS_NATIVE_RANS
static NSString *_rdv2ErrorMessage(int rc) {
    switch (rc) {
        case -1: return @"invalid parameters";
        case -2: return @"out of memory in native code";
        case -3: return @"corrupt encoded blob";
        case -6: return @"ESC substream length mismatch";
        case -7: return @"reserved ESC stream_id";
        default: return [NSString stringWithFormat:@"native error %d", rc];
    }
}
#endif

@implementation TTIORefDiffV2

+ (nullable NSData *)encodeSequences:(NSData *)sequences
                              offsets:(NSData *)offsets
                            positions:(NSData *)positions
                         cigarStrings:(NSArray<NSString *> *)cigarStrings
                            reference:(NSData *)reference
                         referenceMd5:(NSData *)referenceMd5
                         referenceUri:(NSString *)referenceUri
                       readsPerSlice:(NSUInteger)readsPerSlice
                                error:(NSError **)error {
#if !TTIO_HAS_NATIVE_RANS
    if (error) {
        *error = [NSError errorWithDomain:TTIORefDiffV2ErrorDomain
                                     code:-100
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            @"libttio_rans not linked"}];
    }
    return nil;
#else
    if ([referenceMd5 length] != 16) {
        if (error) {
            *error = [NSError errorWithDomain:TTIORefDiffV2ErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"referenceMd5 must be 16 bytes"}];
        }
        return nil;
    }
    NSUInteger n = [positions length] / sizeof(int64_t);
    if ([offsets length] != (n + 1) * sizeof(uint64_t)) {
        if (error) {
            *error = [NSError errorWithDomain:TTIORefDiffV2ErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"offsets length must be (n_reads + 1) * 8"}];
        }
        return nil;
    }
    if ([cigarStrings count] != n) {
        if (error) {
            *error = [NSError errorWithDomain:TTIORefDiffV2ErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"cigarStrings count must equal n_reads"}];
        }
        return nil;
    }

    /* Marshal cigarStrings -> const char ** (kept alive via NSData copies). */
    const char **cigars = (const char **)malloc((n > 0 ? n : 1) * sizeof(const char *));
    NSMutableArray *cigarBytes = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        NSData *bytes = [cigarStrings[i] dataUsingEncoding:NSUTF8StringEncoding];
        /* Append nul terminator; dataUsingEncoding: does not include one. */
        NSMutableData *terminated = [NSMutableData dataWithData:bytes];
        char nul = 0;
        [terminated appendBytes:&nul length:1];
        [cigarBytes addObject:terminated];
        cigars[i] = (const char *)[terminated bytes];
    }

    NSData *uriBytes = [referenceUri dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *uriTerminated = [NSMutableData dataWithData:uriBytes];
    char nul = 0;
    [uriTerminated appendBytes:&nul length:1];

    /* Compute total_bases from offsets array. */
    uint64_t total_bases = 0;
    if (n > 0) {
        const uint64_t *off = (const uint64_t *)[offsets bytes];
        total_bases = off[n];
    }

    ttio_ref_diff_v2_input in = {
        .sequences        = (const uint8_t *)[sequences bytes],
        .offsets          = (const uint64_t *)[offsets bytes],
        .positions        = (const int64_t *)[positions bytes],
        .cigar_strings    = cigars,
        .n_reads          = (uint64_t)n,
        .reference        = (const uint8_t *)[reference bytes],
        .reference_length = (uint64_t)[reference length],
        .reads_per_slice  = (uint64_t)readsPerSlice,
        .reference_md5    = (const uint8_t *)[referenceMd5 bytes],
        .reference_uri    = (const char *)[uriTerminated bytes],
    };

    size_t cap = ttio_ref_diff_v2_max_encoded_size((uint64_t)n, total_bases);
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    size_t out_len = cap;

    int rc = ttio_ref_diff_v2_encode(&in, (uint8_t *)[out mutableBytes], &out_len);
    free(cigars);

    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:TTIORefDiffV2ErrorDomain
                                         code:rc
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                _rdv2ErrorMessage(rc)}];
        }
        return nil;
    }
    [out setLength:out_len];
    return out;
#endif
}

+ (BOOL)decodeData:(NSData *)encoded
          positions:(NSData *)positions
       cigarStrings:(NSArray<NSString *> *)cigarStrings
          reference:(NSData *)reference
            nReads:(NSUInteger)nReads
        totalBases:(NSUInteger)totalBases
      outSequences:(NSData * _Nullable * _Nonnull)outSequences
        outOffsets:(NSData * _Nullable * _Nonnull)outOffsets
              error:(NSError **)error {
#if !TTIO_HAS_NATIVE_RANS
    if (error) {
        *error = [NSError errorWithDomain:TTIORefDiffV2ErrorDomain
                                     code:-100
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            @"libttio_rans not linked"}];
    }
    return NO;
#else
    if ([cigarStrings count] != nReads) {
        if (error) {
            *error = [NSError errorWithDomain:TTIORefDiffV2ErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"cigarStrings count must equal nReads"}];
        }
        return NO;
    }

    const char **cigars = (const char **)malloc((nReads > 0 ? nReads : 1) * sizeof(const char *));
    NSMutableArray *cigarBytes = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        NSData *bytes = [cigarStrings[i] dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *terminated = [NSMutableData dataWithData:bytes];
        char nul = 0;
        [terminated appendBytes:&nul length:1];
        [cigarBytes addObject:terminated];
        cigars[i] = (const char *)[terminated bytes];
    }

    NSMutableData *seqOut = [NSMutableData dataWithLength:(totalBases > 0 ? totalBases : 1)];
    NSMutableData *offOut = [NSMutableData dataWithLength:(nReads + 1) * sizeof(uint64_t)];

    int rc = ttio_ref_diff_v2_decode(
        (const uint8_t *)[encoded bytes], [encoded length],
        (const int64_t *)[positions bytes], cigars,
        (uint64_t)nReads,
        (const uint8_t *)[reference bytes], (uint64_t)[reference length],
        (uint8_t *)[seqOut mutableBytes], (uint64_t *)[offOut mutableBytes]);
    free(cigars);

    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:TTIORefDiffV2ErrorDomain
                                         code:rc
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                _rdv2ErrorMessage(rc)}];
        }
        return NO;
    }

    if (totalBases == 0) {
        *outSequences = [NSData data];
    } else {
        [seqOut setLength:totalBases];
        *outSequences = seqOut;
    }
    *outOffsets = offOut;
    return YES;
#endif
}

@end
