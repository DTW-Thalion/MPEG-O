#ifndef TTIO_NUMPRESS_H
#define TTIO_NUMPRESS_H

#import <Foundation/Foundation.h>

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Core/TTIONumpress.h</p>
 *
 * <p>Lossy numeric compression for monotonically-varying float64
 * signals (mass-spectrometer m/z arrays, retention times, ...).
 * Clean-room implementation of the algorithm in Teleman et al.,
 * <em>MCP</em> 13(6):1537-1542 (2014),
 * <code>doi:10.1074/mcp.O114.037879</code>.</p>
 *
 * <p>The algorithm applies a fixed-point scaling factor then stores
 * first differences of the quantised integers. For typical m/z data
 * in the 100-2000 range, a 62-bit fixed-point representation keeps
 * the round-trip relative error well under one part per million,
 * and the first-difference stage makes the resulting integer array
 * highly compressible by a downstream codec (zlib, LZ4, ...).</p>
 *
 * <p>Unlike the ms-numpress library's wire format, this
 * implementation emits a plain <code>int64</code> delta array that
 * can be stored in an HDF5 dataset, attribute-annotated with the
 * chosen <code>scale</code>, and reused by any language with
 * cumsum and divide primitives. It is byte-identical between the
 * TTI-O Objective-C, Python, and Java implementations by
 * construction: every side uses the same scale computation, the
 * same rounding rule, and the same delta pass.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio._numpress</code><br/>
 * Java: <code>global.thalion.ttio.NumpressCodec</code></p>
 */
@interface TTIONumpress : NSObject

/**
 * Computes the fixed-point scale factor for a value range. The
 * scale is chosen so that the largest absolute value occupies at
 * most 62 bits after multiplication, leaving headroom for delta
 * overflow.
 *
 * @param minValue Minimum value in the input range.
 * @param maxValue Maximum value in the input range.
 * @return Scaling factor to pass to
 *         <code>+encodeFloat64:count:scale:outDeltas:</code> and
 *         <code>+decodeInt64:count:scale:outValues:</code>.
 */
+ (int64_t)scaleForValueRangeMin:(double)minValue
                             max:(double)maxValue;

/**
 * Encodes a float64 array as an int64 first-difference array.
 *
 * @param values    Input array of length <code>count</code>.
 * @param count     Number of samples.
 * @param scale     Fixed-point scaling factor (compute via
 *                  <code>+scaleForValueRangeMin:max:</code>).
 * @param outDeltas Output buffer of <code>count</code>
 *                  <code>int64</code> entries.
 * @return <code>YES</code> on success.
 */
+ (BOOL)encodeFloat64:(const double *)values
                count:(NSUInteger)count
                scale:(int64_t)scale
            outDeltas:(int64_t *)outDeltas;

/**
 * Decodes an int64 first-difference array back to float64.
 *
 * @param deltas    Input array of <code>count</code> deltas.
 * @param count     Number of samples.
 * @param scale     Same fixed-point scaling factor used at encode.
 * @param outValues Output buffer of <code>count</code> float64
 *                  values.
 * @return <code>YES</code> on success.
 */
+ (BOOL)decodeInt64:(const int64_t *)deltas
              count:(NSUInteger)count
              scale:(int64_t)scale
          outValues:(double *)outValues;

@end

#endif /* TTIO_NUMPRESS_H */
