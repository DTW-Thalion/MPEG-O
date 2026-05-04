/*
 * TTIORefDiffV2.h -- CRAM-style bit-packed sequence diff codec (codec id 14).
 *
 * Spec: docs/superpowers/specs/2026-05-03-ref-diff-v2-design.md
 *
 * Direct link to the C library entries ttio_ref_diff_v2_encode /
 * _decode in libttio_rans (header at <ttio_rans.h>). Pure-ObjC
 * fallback returns nil + error if libttio_rans not linked at build
 * time.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_REF_DIFF_V2_H
#define TTIO_REF_DIFF_V2_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TTIORefDiffV2ErrorDomain;

@interface TTIORefDiffV2 : NSObject

/// Encode a slice of reads to the refdiff_v2 blob.
///
/// All NSData inputs are interpreted as parallel typed arrays:
/// sequences (uint8 ACGTN), offsets (uint64 LE, n+1 entries),
/// positions (int64 LE, n entries), reference (uint8), referenceMd5 (16 bytes).
+ (nullable NSData *)encodeSequences:(NSData *)sequences
                              offsets:(NSData *)offsets
                            positions:(NSData *)positions
                         cigarStrings:(NSArray<NSString *> *)cigarStrings
                            reference:(NSData *)reference
                         referenceMd5:(NSData *)referenceMd5
                         referenceUri:(NSString *)referenceUri
                       readsPerSlice:(NSUInteger)readsPerSlice
                                error:(NSError **)error;

/// Decode a refdiff_v2 blob to (sequences, offsets).
+ (BOOL)decodeData:(NSData *)encoded
          positions:(NSData *)positions
       cigarStrings:(NSArray<NSString *> *)cigarStrings
          reference:(NSData *)reference
            nReads:(NSUInteger)nReads
        totalBases:(NSUInteger)totalBases
      outSequences:(NSData * _Nullable * _Nonnull)outSequences
        outOffsets:(NSData * _Nullable * _Nonnull)outOffsets
              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_REF_DIFF_V2_H */
