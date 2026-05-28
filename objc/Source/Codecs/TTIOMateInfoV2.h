/*
 * TTIOMateInfoV2.h — CRAM-style inline mate-pair codec (codec id 13).
 *
 * Spec: docs/superpowers/specs/2026-05-03-mate-info-v2-design.md
 *
 * Direct link to the C library entries ttio_mate_info_v2_encode /
 * _decode in libttio_rans (header at <ttio_rans.h>). Pure-ObjC
 * fallback returns nil + error if libttio_rans not linked at build
 * time.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_MATE_INFO_V2_H
#define TTIO_MATE_INFO_V2_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TTIOMateInfoV2ErrorDomain;

@interface TTIOMateInfoV2 : NSObject

/**
 * Whether the native `libttio_rans` mate-info v2 entries are usable.
 *
 * Returns YES iff `libttio_rans` is linked and the
 * `ttio_mate_info_v2_encode` / `_decode` symbols are reachable. Tests
 * guard on this before exercising the dispatch path; the pure-ObjC
 * fallback otherwise returns nil + error.
 *
 * @return YES if the native codec is available, NO otherwise.
 */
+ (BOOL)nativeAvailable;

/**
 * Encode mate-pair fields to the codec-13 inline-v2 blob.
 *
 * All `NSData` inputs are parallel arrays interpreted as fixed-width
 * typed elements: `mateChromIds` int32, `matePositions` int64,
 * `templateLengths` int32, `ownChromIds` uint16, `ownPositions` int64.
 * Mate vs own fields are differenced internally before rANS encoding
 * (the CRAM trick the codec is named after).
 *
 * @param mateChromIds     int32 mate-chromosome IDs (one per record).
 * @param matePositions    int64 mate-position values.
 * @param templateLengths  int32 template-length values.
 * @param ownChromIds      uint16 own-chromosome IDs (for diff coding).
 * @param ownPositions     int64 own-position values (for diff coding).
 * @param error            Out-error on invalid input or native failure.
 * @return Encoded inline-v2 blob bytes, or `nil` with `*error` set.
 */
+ (nullable NSData *)encodeMateChromIds:(NSData *)mateChromIds
                          matePositions:(NSData *)matePositions
                        templateLengths:(NSData *)templateLengths
                            ownChromIds:(NSData *)ownChromIds
                           ownPositions:(NSData *)ownPositions
                                  error:(NSError **)error;

/**
 * Decode an inline-v2 blob back into the three parallel mate-info channels.
 *
 * Inverse of `+encodeMateChromIds:...`. Requires the `ownChromIds` /
 * `ownPositions` channels for diff reversal — these are stored
 * unencoded in the parent container and reach the decoder via the
 * caller.
 *
 * @param encoded             Inline-v2 blob produced by the encoder.
 * @param ownChromIds         uint16 own-chromosome IDs.
 * @param ownPositions        int64 own-position values.
 * @param nRecords            Expected record count (cross-checked
 *                            against the blob's internal frame).
 * @param outMateChromIds     Out: int32 mate-chromosome IDs.
 * @param outMatePositions    Out: int64 mate-position values.
 * @param outTemplateLengths  Out: int32 template-length values.
 * @param error               Out-error on bad input or decode failure.
 * @return YES on success with the three out-channels populated, NO on
 *         failure with `*error` set and out-channels unchanged.
 */
+ (BOOL)decodeData:(NSData *)encoded
       ownChromIds:(NSData *)ownChromIds
      ownPositions:(NSData *)ownPositions
          nRecords:(NSUInteger)nRecords
   outMateChromIds:(NSData * _Nullable * _Nonnull)outMateChromIds
  outMatePositions:(NSData * _Nullable * _Nonnull)outMatePositions
outTemplateLengths:(NSData * _Nullable * _Nonnull)outTemplateLengths
             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_MATE_INFO_V2_H */
