/*
 * TTIOCanonicalBytes.h — v0.7 M43 canonical byte-layout helpers.
 *
 * Every storage provider emits the same byte stream for the same
 * logical data so a file signed or encrypted through one provider
 * verifies through any other. The canonical layout is:
 *
 *   - Primitive numeric: little-endian packed values.
 *   - Compound: rows in storage order; fields in declaration order.
 *       VL strings as u32_le(length) || utf-8_bytes.
 *       Numeric fields little-endian.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_CANONICAL_BYTES_H
#define TTIO_CANONICAL_BYTES_H

#import <Foundation/Foundation.h>
#import "../ValueClasses/TTIOEnums.h"
#import "TTIOCompoundField.h"

NS_ASSUME_NONNULL_BEGIN

/** Shared helpers used by every provider's @c -readCanonicalBytes:
 *  implementation. Usable independently as well — tests and byte-parity
 *  tooling walk rows with the same layout.
 *
 *  @since 0.7 */
@interface TTIOCanonicalBytes : NSObject

/** Canonicalise a primitive numeric buffer to little-endian.
 *
 *  On x86/x86_64 (little-endian native) this is an identity copy. On
 *  big-endian hosts each element is byteswapped. @c precision selects
 *  the element width; TTIOPrecisionComplex128 is treated as a pair of
 *  float64 values per element. */
+ (NSData *)canonicalBytesForNumericData:(NSData *)data
                                precision:(TTIOPrecision)precision;

/** Canonicalise a list-of-dicts compound result. Rows are walked in
 *  order; each row's fields are emitted in the declared @c fields
 *  order (NOT the dictionary's internal iteration order, which is
 *  unspecified). */
+ (NSData *)canonicalBytesForCompoundRows:(NSArray<NSDictionary<NSString *, id> *> *)rows
                                    fields:(NSArray<TTIOCompoundField *> *)fields;

@end

NS_ASSUME_NONNULL_END

#endif
