#ifndef MPGO_ENCODING_SPEC_H
#define MPGO_ENCODING_SPEC_H

#import <Foundation/Foundation.h>
#import "MPGOEnums.h"

/**
 * Describes how a SignalArray's buffer is encoded: numeric precision,
 * compression algorithm, and byte order. Immutable value class.
 */
@interface MPGOEncodingSpec : NSObject <NSCoding, NSCopying>

@property (readonly) MPGOPrecision    precision;
@property (readonly) MPGOCompression  compressionAlgorithm;
@property (readonly) MPGOByteOrder    byteOrder;

- (instancetype)initWithPrecision:(MPGOPrecision)precision
             compressionAlgorithm:(MPGOCompression)compression
                        byteOrder:(MPGOByteOrder)byteOrder;

+ (instancetype)specWithPrecision:(MPGOPrecision)precision
             compressionAlgorithm:(MPGOCompression)compression
                        byteOrder:(MPGOByteOrder)byteOrder;

/** Returns the size in bytes of a single element at this precision. */
- (NSUInteger)elementSize;

@end

#endif /* MPGO_ENCODING_SPEC_H */
