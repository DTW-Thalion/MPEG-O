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

/// Returns YES when libttio_rans is linked and the encode/decode
/// symbols are available at runtime. Tests guard on this before
/// exercising the dispatch path.
+ (BOOL)nativeAvailable;

/// Encode a mate triple to the inline_v2 blob.
///
/// All NSData inputs are interpreted as parallel arrays of the noted
/// typed elements (int32, int64, int32, uint16, int64). Returns nil +
/// error on invalid input or native error.
+ (nullable NSData *)encodeMateChromIds:(NSData *)mateChromIds
                          matePositions:(NSData *)matePositions
                        templateLengths:(NSData *)templateLengths
                            ownChromIds:(NSData *)ownChromIds
                           ownPositions:(NSData *)ownPositions
                                  error:(NSError **)error;

/// Decode an inline_v2 blob to (mate_chrom_ids, mate_positions,
/// template_lengths). Returns YES on success, NO + error on failure.
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
