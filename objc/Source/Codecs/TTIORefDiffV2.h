/*
 * TTIORefDiffV2.h -- CRAM-style bit-packed sequence diff codec (codec id 14).
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

/**
 * Whether the native `libttio_rans` ref-diff v2 entries are usable.
 *
 * Returns YES iff `libttio_rans` is linked and the
 * `ttio_ref_diff_v2_encode` / `_decode` symbols are reachable. Tests
 * guard on this before exercising the dispatch path.
 *
 * @return YES if the native codec is available, NO otherwise.
 */
+ (BOOL)nativeAvailable;

/**
 * Encode a slice of reads to the codec-14 refdiff-v2 blob.
 *
 * All `NSData` inputs are parallel typed arrays: `sequences` uint8
 * (ACGTN), `offsets` uint64 LE (n+1 entries), `positions` int64 LE
 * (n entries), `reference` uint8, `referenceMd5` 16 bytes. Reads are
 * diffed against the reference and the remainder rANS-encoded.
 *
 * @param sequences      Concatenated read bases (uint8 ACGTN).
 * @param offsets        Per-read offsets into `sequences` (n+1 uint64 LE).
 * @param positions      Per-read reference positions (int64 LE).
 * @param cigarStrings   Per-read CIGAR strings (used to skip soft-clips).
 * @param reference      Reference-FASTA bytes for diffing.
 * @param referenceMd5   16-byte MD5 of the reference (stored in the blob).
 * @param referenceUri   Reference URI string (stored in the blob).
 * @param readsPerSlice  Reads per slice (CRAM-style sub-block partition).
 * @param error          Out-error on invalid input or native failure.
 * @return Encoded refdiff-v2 blob bytes, or `nil` with `*error` set.
 */
+ (nullable NSData *)encodeSequences:(NSData *)sequences
                              offsets:(NSData *)offsets
                            positions:(NSData *)positions
                         cigarStrings:(NSArray<NSString *> *)cigarStrings
                            reference:(NSData *)reference
                         referenceMd5:(NSData *)referenceMd5
                         referenceUri:(NSString *)referenceUri
                       readsPerSlice:(NSUInteger)readsPerSlice
                                error:(NSError **)error;

/**
 * Encode with a byte budget on the slice partition (M97).
 *
 * Identical to `+encodeSequences:...readsPerSlice:error:` except that
 * with `sliceBytes` > 0 a slice closes before the read that would
 * push it past `sliceBytes` bases; `readsPerSlice` still caps the
 * read count and every slice keeps at least one read. Writer policy
 * only — the wire format and decoder are unchanged, and
 * `sliceBytes` = 0 reproduces the fixed-count output byte for byte.
 *
 * @param sequences      Concatenated read bases (uint8 ACGTN).
 * @param offsets        Per-read offsets into `sequences` (n+1 uint64 LE).
 * @param positions      Per-read reference positions (int64 LE).
 * @param cigarStrings   Per-read CIGAR strings (used to skip soft-clips).
 * @param reference      Reference-FASTA bytes for diffing.
 * @param referenceMd5   16-byte MD5 of the reference (stored in the blob).
 * @param referenceUri   Reference URI string (stored in the blob).
 * @param readsPerSlice  Reads per slice (CRAM-style sub-block partition).
 * @param sliceBytes     Slice byte budget; 0 = the fixed-count rule.
 * @param error          Out-error on invalid input or native failure.
 * @return Encoded refdiff-v2 blob bytes, or `nil` with `*error` set.
 */
+ (nullable NSData *)encodeSequences:(NSData *)sequences
                              offsets:(NSData *)offsets
                            positions:(NSData *)positions
                         cigarStrings:(NSArray<NSString *> *)cigarStrings
                            reference:(NSData *)reference
                         referenceMd5:(NSData *)referenceMd5
                         referenceUri:(NSString *)referenceUri
                       readsPerSlice:(NSUInteger)readsPerSlice
                          sliceBytes:(unsigned long long)sliceBytes
                                error:(NSError **)error;

/**
 * Decode a refdiff-v2 blob back into the sequence + offset channels.
 *
 * Inverse of `+encodeSequences:...`. Requires the unencoded
 * `positions`, CIGAR strings, and reference bytes — the codec stores
 * only the diff, so the reference must be re-supplied at decode time.
 *
 * @param encoded       Refdiff-v2 blob produced by the encoder.
 * @param positions     Per-read reference positions (int64 LE).
 * @param cigarStrings  Per-read CIGAR strings.
 * @param reference     Reference-FASTA bytes (same as at encode time).
 * @param nReads        Expected read count (validated against frame).
 * @param totalBases    Expected total decoded base count.
 * @param outSequences  Out: concatenated read bases (uint8 ACGTN).
 * @param outOffsets    Out: per-read offsets (n+1 uint64 LE).
 * @param error         Out-error on bad input or decode failure.
 * @return YES on success with both out-channels populated, NO on
 *         failure with `*error` set.
 */
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
