/*
 * TTIONameTokenizerV2.h -- column-aware tokenised read-name codec (codec id 15).
 *
 * Spec: docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md
 *
 * Direct link to the C library entries ttio_name_tok_v2_encode /
 * _decode in libttio_rans (header at <ttio_rans.h>). Pure-ObjC fallback
 * raises NSException / returns nil + error if libttio_rans is not
 * linked at build time.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_NAME_TOKENIZER_V2_H
#define TTIO_NAME_TOKENIZER_V2_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TTIONameTokenizerV2ErrorDomain;

@interface TTIONameTokenizerV2 : NSObject

/// YES when libttio_rans is linked and the v2 codec functions are available.
+ (BOOL)nativeAvailable;

/// Encode an ordered list of ASCII read names to a NAME_TOKENIZED v2 blob.
+ (NSData *)encodeNames:(NSArray<NSString *> *)names;

/// Decode a NAME_TOKENIZED v2 blob to its read-name list. Returns nil and
/// sets *error on bad magic/version/decode failure.
+ (nullable NSArray<NSString *> *)decodeData:(NSData *)blob
                                        error:(NSError **)error;

/// Backend identifier (always "native" when libttio_rans is linked).
+ (NSString *)backendName;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_NAME_TOKENIZER_V2_H */
