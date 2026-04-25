#ifndef TTIO_ENCODING_SPEC_H
#define TTIO_ENCODING_SPEC_H

#import <Foundation/Foundation.h>
#import "TTIOEnums.h"

/**
 * Describes how a SignalArray's buffer is encoded: numeric precision,
 * compression algorithm, and byte order. Immutable value class.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.encoding_spec.EncodingSpec
 *   Java:   com.dtwthalion.tio.EncodingSpec
 */
@interface TTIOEncodingSpec : NSObject <NSCoding, NSCopying>

@property (readonly) TTIOPrecision    precision;
@property (readonly) TTIOCompression  compressionAlgorithm;
@property (readonly) TTIOByteOrder    byteOrder;

- (instancetype)initWithPrecision:(TTIOPrecision)precision
             compressionAlgorithm:(TTIOCompression)compression
                        byteOrder:(TTIOByteOrder)byteOrder;

+ (instancetype)specWithPrecision:(TTIOPrecision)precision
             compressionAlgorithm:(TTIOCompression)compression
                        byteOrder:(TTIOByteOrder)byteOrder;

/** Returns the size in bytes of a single element at this precision. */
- (NSUInteger)elementSize;

@end

#endif /* TTIO_ENCODING_SPEC_H */
