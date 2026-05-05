/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_CANONICAL_BYTES_H
#define TTIO_CANONICAL_BYTES_H

#import <Foundation/Foundation.h>
#import "../ValueClasses/TTIOEnums.h"
#import "TTIOCompoundField.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <heading>TTIOCanonicalBytes</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOCanonicalBytes.h</p>
 *
 * <p>Shared canonical byte-layout helpers used by every storage
 * provider's <code>-readCanonicalBytes:</code> implementation. The
 * canonical layout guarantees that a file signed or encrypted
 * through one provider verifies through any other:</p>
 *
 * <ul>
 *  <li>Primitive numeric: little-endian packed values.</li>
 *  <li>Compound: rows in storage order; fields in declaration order.
 *      VL strings as
 *      <code>u32_le(length) || utf-8_bytes</code>; numeric fields
 *      little-endian.</li>
 * </ul>
 *
 * <p>Usable independently &mdash; tests and byte-parity tooling walk
 * rows with the same layout.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 */
@interface TTIOCanonicalBytes : NSObject

/**
 * Canonicalises a primitive numeric buffer to little-endian. On
 * x86 / x86_64 (little-endian native) this is an identity copy. On
 * big-endian hosts each element is byte-swapped.
 * <code>TTIOPrecisionComplex128</code> is treated as a pair of
 * float64 values per element.
 *
 * @param data      Primitive numeric buffer.
 * @param precision Element width selector.
 * @return The canonicalised little-endian buffer.
 */
+ (NSData *)canonicalBytesForNumericData:(NSData *)data
                                precision:(TTIOPrecision)precision;

/**
 * Canonicalises a list-of-dicts compound result. Rows are walked in
 * order; each row's fields are emitted in the declared
 * <code>fields</code> order (not the dictionary's internal
 * iteration order, which is unspecified).
 *
 * @param rows   Compound rows in storage order.
 * @param fields Field schema in declaration order.
 * @return The canonicalised byte stream.
 */
+ (NSData *)canonicalBytesForCompoundRows:(NSArray<NSDictionary<NSString *, id> *> *)rows
                                    fields:(NSArray<TTIOCompoundField *> *)fields;

@end

NS_ASSUME_NONNULL_END

#endif
