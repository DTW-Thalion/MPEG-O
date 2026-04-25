#ifndef TTIO_NUMPRESS_H
#define TTIO_NUMPRESS_H

#import <Foundation/Foundation.h>

/**
 * ``TTIONumpress`` — lossy numeric compression for monotonically
 * varying float64 signals (mass spectrometer m/z, retention time, ...).
 *
 * **Clean-room implementation from Teleman et al. 2014** (*MCP*
 * 13(6):1537-1542, doi:10.1074/mcp.O114.037879).
 *
 * The algorithm applies a fixed-point scaling factor then stores
 * first differences of the quantised integers. For typical m/z data
 * in the 100–2000 range a 62-bit fixed-point representation keeps
 * the round-trip relative error well under one part per million, and
 * the first-difference stage makes the resulting integer array
 * highly compressible by a downstream codec (zlib, LZ4, ...).
 *
 * Unlike the ms-numpress library's wire format, this implementation
 * emits a plain ``int64`` delta array that can be stored in an HDF5
 * dataset, attribute-annotated with the chosen ``scale``, and reused
 * by any language with cumsum / divide primitives. It is
 * byte-identical between the TTIO Objective-C and Python
 * implementations by construction: both sides use the same scale
 * computation, the same rounding rule, and the same delta pass.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio._numpress
 *   Java:   com.dtwthalion.tio.NumpressCodec
 */
@interface TTIONumpress : NSObject

/**
 * Compute the fixed-point scale factor for a value range. The scale
 * is chosen so that the largest absolute value occupies at most 62
 * bits after multiplication, leaving headroom for delta overflow.
 */
+ (int64_t)scaleForValueRangeMin:(double)minValue
                             max:(double)maxValue;

/** Encode a float64 array as an int64 first-difference array.
 *  ``scale`` is the fixed-point scaling factor; the caller passes in
 *  the same value used on decode. ``count`` is the number of samples.
 *  Returns ``YES`` on success; writes ``count`` int64 entries into
 *  ``outDeltas``.
 */
+ (BOOL)encodeFloat64:(const double *)values
                count:(NSUInteger)count
                scale:(int64_t)scale
            outDeltas:(int64_t *)outDeltas;

/** Decode an int64 first-difference array back to float64. */
+ (BOOL)decodeInt64:(const int64_t *)deltas
              count:(NSUInteger)count
              scale:(int64_t)scale
         outValues:(double *)outValues;

@end

#endif /* TTIO_NUMPRESS_H */
