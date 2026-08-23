/*
 * TTIONameTokenizerV2.h -- column-aware tokenised read-name codec (codec id 15).
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

/**
 * Whether the native `libttio_rans` name-tokenizer v2 entries are usable.
 *
 * Returns YES iff `libttio_rans` is linked and the
 * `ttio_name_tok_v2_encode` / `_decode` symbols are reachable.
 *
 * @return YES if the native codec is available, NO otherwise.
 */
+ (BOOL)nativeAvailable;

/**
 * Encode an ordered list of ASCII read names to a NAME_TOKENIZED v2 blob.
 *
 * Column-aware tokeniser: splits each name on `:` / `_` / `.` / `#`,
 * then rANS-encodes the per-column streams. Empty input yields an
 * empty blob.
 *
 * @param names  Read names in record order. ASCII only.
 * @return Encoded blob bytes ready to be stored as the codec-15 channel.
 */
+ (NSData *)encodeNames:(NSArray<NSString *> *)names;

/**
 * Decode a NAME_TOKENIZED v2 blob back into its read-name list.
 *
 * Inverse of `+encodeNames:`. Verifies the v2 magic and version
 * before decoding; bad framing populates `*error`.
 *
 * @param blob   Encoded codec-15 channel bytes.
 * @param error  Out-error on bad magic, unknown version, or decode
 *               failure.
 * @return Read names in record order, or `nil` with `*error` set.
 */
+ (nullable NSArray<NSString *> *)decodeData:(NSData *)blob
                                        error:(NSError **)error;

/**
 * Backend identifier string describing the active implementation.
 *
 * @return `@"native"` when `libttio_rans` is linked; reserved for
 *         future fallback identifiers.
 */
+ (NSString *)backendName;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_NAME_TOKENIZER_V2_H */
