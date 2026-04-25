#ifndef TTIO_SIGNAL_ARRAY_H
#define TTIO_SIGNAL_ARRAY_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOCVAnnotatable.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOCVParam.h"

@class TTIOHDF5Group;
@class TTIOHDF5Dataset;

/**
 * The atomic unit of measured signal in TTI-O. A SignalArray is a
 * typed numeric buffer with an encoding spec, an optional axis descriptor,
 * and an arbitrary number of CV annotations.
 *
 * Construction is via -initWithBuffer:length:encoding:axis: with raw
 * bytes; the caller is responsible for matching the buffer layout to
 * the encoding's elementSize. HDF5 round-trip is via -writeToGroup:name:
 * and +readFromGroup:name:.
 *
 * Not thread-safe. Mutating CV annotations from multiple threads is
 * undefined.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.signal_array.SignalArray
 *   Java:   global.thalion.ttio.SignalArray
 */
@interface TTIOSignalArray : NSObject <TTIOCVAnnotatable>

@property (readonly, copy)   NSData              *buffer;
@property (readonly)         NSUInteger           length;
@property (readonly, strong) TTIOEncodingSpec    *encoding;
@property (readonly, strong) TTIOAxisDescriptor  *axis;        // nullable

- (instancetype)initWithBuffer:(NSData *)buffer
                        length:(NSUInteger)length
                      encoding:(TTIOEncodingSpec *)encoding
                          axis:(TTIOAxisDescriptor *)axis;

#pragma mark - HDF5 round-trip

- (BOOL)writeToGroup:(TTIOHDF5Group *)group
                name:(NSString *)name
           chunkSize:(NSUInteger)chunkSize
    compressionLevel:(int)compressionLevel
               error:(NSError **)error;

+ (instancetype)readFromGroup:(TTIOHDF5Group *)group
                         name:(NSString *)name
                        error:(NSError **)error;

#pragma mark - Equality

- (BOOL)isEqual:(id)other;
- (NSUInteger)hash;

@end

#endif
