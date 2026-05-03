/*
 * TTIOMateInfoV2.m — CRAM-style inline mate-pair codec (codec id 13).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOMateInfoV2.h"

#if __has_include(<ttio_rans.h>)
#include <ttio_rans.h>
#define TTIO_HAS_NATIVE_RANS 1
#else
#define TTIO_HAS_NATIVE_RANS 0
#endif

NSString *const TTIOMateInfoV2ErrorDomain = @"global.thalion.ttio.MateInfoV2";

#if TTIO_HAS_NATIVE_RANS
static NSString *_mivErrorMessage(int rc) {
    switch (rc) {
        case -1: return @"invalid parameters";
        case -2: return @"out of memory in native code";
        case -3: return @"corrupt encoded blob";
        case -4: return @"reserved MF value 3";
        case -5: return @"NS substream length mismatch";
        default: return [NSString stringWithFormat:@"native error %d", rc];
    }
}
#endif

@implementation TTIOMateInfoV2

+ (nullable NSData *)encodeMateChromIds:(NSData *)mateChromIds
                          matePositions:(NSData *)matePositions
                        templateLengths:(NSData *)templateLengths
                            ownChromIds:(NSData *)ownChromIds
                           ownPositions:(NSData *)ownPositions
                                  error:(NSError **)error {
#if !TTIO_HAS_NATIVE_RANS
    if (error) {
        *error = [NSError errorWithDomain:TTIOMateInfoV2ErrorDomain
                                     code:-100
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            @"libttio_rans not linked"}];
    }
    return nil;
#else
    NSUInteger n = [mateChromIds length] / sizeof(int32_t);
    if ([matePositions length] != n * sizeof(int64_t) ||
        [templateLengths length] != n * sizeof(int32_t) ||
        [ownChromIds length] != n * sizeof(uint16_t) ||
        [ownPositions length] != n * sizeof(int64_t)) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOMateInfoV2ErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"input array length mismatch"}];
        }
        return nil;
    }

    /* Validate mate_chrom_ids >= -1 (matches native miv2_classify_mf). */
    const int32_t *mc = (const int32_t *)[mateChromIds bytes];
    for (NSUInteger i = 0; i < n; i++) {
        if (mc[i] < -1) {
            if (error) {
                *error = [NSError errorWithDomain:TTIOMateInfoV2ErrorDomain
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                     @"invalid mate_chrom_id at index %lu: %d",
                                                     (unsigned long)i, mc[i]]}];
            }
            return nil;
        }
    }

    size_t cap = ttio_mate_info_v2_max_encoded_size((uint64_t)n);
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    size_t out_len = cap;

    int rc = ttio_mate_info_v2_encode(
        mc,
        (const int64_t *)[matePositions bytes],
        (const int32_t *)[templateLengths bytes],
        (const uint16_t *)[ownChromIds bytes],
        (const int64_t *)[ownPositions bytes],
        (uint64_t)n,
        (uint8_t *)[out mutableBytes],
        &out_len);
    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOMateInfoV2ErrorDomain
                                         code:rc
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                _mivErrorMessage(rc)}];
        }
        return nil;
    }
    [out setLength:out_len];
    return out;
#endif
}

+ (BOOL)decodeData:(NSData *)encoded
       ownChromIds:(NSData *)ownChromIds
      ownPositions:(NSData *)ownPositions
          nRecords:(NSUInteger)nRecords
   outMateChromIds:(NSData * _Nullable * _Nonnull)outMateChromIds
  outMatePositions:(NSData * _Nullable * _Nonnull)outMatePositions
outTemplateLengths:(NSData * _Nullable * _Nonnull)outTemplateLengths
             error:(NSError **)error {
#if !TTIO_HAS_NATIVE_RANS
    if (error) {
        *error = [NSError errorWithDomain:TTIOMateInfoV2ErrorDomain
                                     code:-100
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            @"libttio_rans not linked"}];
    }
    return NO;
#else
    NSMutableData *mc = [NSMutableData dataWithLength:nRecords * sizeof(int32_t)];
    NSMutableData *mp = [NSMutableData dataWithLength:nRecords * sizeof(int64_t)];
    NSMutableData *ts = [NSMutableData dataWithLength:nRecords * sizeof(int32_t)];

    int rc = ttio_mate_info_v2_decode(
        (const uint8_t *)[encoded bytes],
        [encoded length],
        (const uint16_t *)[ownChromIds bytes],
        (const int64_t  *)[ownPositions bytes],
        (uint64_t)nRecords,
        (int32_t *)[mc mutableBytes],
        (int64_t *)[mp mutableBytes],
        (int32_t *)[ts mutableBytes]);
    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOMateInfoV2ErrorDomain
                                         code:rc
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                _mivErrorMessage(rc)}];
        }
        return NO;
    }
    *outMateChromIds   = mc;
    *outMatePositions  = mp;
    *outTemplateLengths = ts;
    return YES;
#endif
}

@end
