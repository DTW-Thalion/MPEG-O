#ifndef TTIO_ENCODING_SPEC_H
#define TTIO_ENCODING_SPEC_H

#import <Foundation/Foundation.h>
#import "TTIOEnums.h"

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCoding, NSCopying</p>
 * <p><em>Declared In:</em> ValueClasses/TTIOEncodingSpec.h</p>
 *
 * <p>Describes how a <code>TTIOSignalArray</code>'s buffer is encoded:
 * numeric precision, compression algorithm, and byte order. Immutable
 * value class with value-based equality.</p>
 *
 * <p>The encoding spec is the wire-format contract for a signal
 * buffer. Storage providers consult <code>precision</code> to
 * compute element size and to map onto the backend's native types
 * (HDF5 datatype, SQLite BLOB layout, in-memory typed array,
 * Zarr chunk dtype). <code>compressionAlgorithm</code> selects
 * between HDF5 filter pipeline codecs (NONE / ZLIB / LZ4 /
 * NUMPRESS_DELTA) and the dedicated per-channel codecs declared in
 * <code>TTIOCompression</code>. <code>byteOrder</code> is fixed at
 * little-endian for cross-platform byte-equality of canonical
 * outputs.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.encoding_spec.EncodingSpec</code><br/>
 * Java: <code>global.thalion.ttio.EncodingSpec</code></p>
 */
@interface TTIOEncodingSpec : NSObject <NSCoding, NSCopying>

/** Numeric precision of each element. */
@property (readonly) TTIOPrecision precision;

/** Compression algorithm applied to the buffer. */
@property (readonly) TTIOCompression compressionAlgorithm;

/** Byte order of multi-byte numeric values. */
@property (readonly) TTIOByteOrder byteOrder;

/**
 * Designated initialiser.
 *
 * @param precision   Element precision enum value.
 * @param compression Compression algorithm enum value.
 * @param byteOrder   Byte order enum value.
 * @return An initialised encoding spec.
 */
- (instancetype)initWithPrecision:(TTIOPrecision)precision
             compressionAlgorithm:(TTIOCompression)compression
                        byteOrder:(TTIOByteOrder)byteOrder;

/**
 * Convenience factory for the designated initialiser.
 *
 * @param precision   Element precision.
 * @param compression Compression algorithm.
 * @param byteOrder   Byte order.
 * @return An autoreleased encoding spec.
 */
+ (instancetype)specWithPrecision:(TTIOPrecision)precision
             compressionAlgorithm:(TTIOCompression)compression
                        byteOrder:(TTIOByteOrder)byteOrder;

/**
 * @return The size in bytes of a single element at this precision
 *         (e.g. 8 for Float64, 4 for Float32, 1 for UInt8, 16 for
 *         Complex128).
 */
- (NSUInteger)elementSize;

@end

#endif /* TTIO_ENCODING_SPEC_H */
