#ifndef MPGO_SIGNAL_ARRAY_H
#define MPGO_SIGNAL_ARRAY_H

#import <Foundation/Foundation.h>
#import "Protocols/MPGOCVAnnotatable.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOCVParam.h"

@class MPGOHDF5Group;
@class MPGOHDF5Dataset;

/**
 * The atomic unit of measured signal in MPEG-O. A SignalArray is a
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
 */
@interface MPGOSignalArray : NSObject <MPGOCVAnnotatable>

@property (readonly, copy)   NSData              *buffer;
@property (readonly)         NSUInteger           length;
@property (readonly, strong) MPGOEncodingSpec    *encoding;
@property (readonly, strong) MPGOAxisDescriptor  *axis;        // nullable

- (instancetype)initWithBuffer:(NSData *)buffer
                        length:(NSUInteger)length
                      encoding:(MPGOEncodingSpec *)encoding
                          axis:(MPGOAxisDescriptor *)axis;

#pragma mark - HDF5 round-trip

- (BOOL)writeToGroup:(MPGOHDF5Group *)group
                name:(NSString *)name
           chunkSize:(NSUInteger)chunkSize
    compressionLevel:(int)compressionLevel
               error:(NSError **)error;

+ (instancetype)readFromGroup:(MPGOHDF5Group *)group
                         name:(NSString *)name
                        error:(NSError **)error;

#pragma mark - Equality

- (BOOL)isEqual:(id)other;
- (NSUInteger)hash;

@end

#endif
