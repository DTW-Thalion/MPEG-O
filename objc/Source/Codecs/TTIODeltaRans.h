/*
 * TTIODeltaRans.h — DELTA_RANS_ORDER0 codec (M95, codec id 11).
 *
 * Delta + zigzag + unsigned LEB128 varint + rANS order-0.
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.delta_rans
 *   Java:   global.thalion.ttio.codecs.DeltaRans
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_DELTA_RANS_H
#define TTIO_DELTA_RANS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSData * _Nullable TTIODeltaRansEncode(NSData *data, uint8_t elementSize,
                                      NSError * _Nullable * _Nullable error);

NSData * _Nullable TTIODeltaRansDecode(NSData *encoded,
                                       NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

#endif /* TTIO_DELTA_RANS_H */
