#ifndef TTIO_HDF5_DATASET_H
#define TTIO_HDF5_DATASET_H

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "ValueClasses/TTIOEnums.h"

/**
 * Thin wrapper around a 1-D HDF5 dataset. Owns its dataset id and (for
 * compound types) the type id; both are released in -dealloc.
 *
 * Datasets are created with a definite element count and precision; the
 * shape cannot be resized after creation.
 */
@interface TTIOHDF5Dataset : NSObject

- (instancetype)initWithDatasetId:(hid_t)did
                        precision:(TTIOPrecision)precision
                           length:(NSUInteger)length
                         retainer:(id)retainer;

@property (readonly) hid_t          datasetId;
@property (readonly) TTIOPrecision  precision;
@property (readonly) NSUInteger     length;

/**
 * Write all elements. The buffer length must match length * elementSize.
 */
- (BOOL)writeData:(NSData *)data error:(NSError **)error;

/**
 * Read all elements. Returns an NSData of length * elementSize bytes.
 */
- (NSData *)readDataWithError:(NSError **)error;

/**
 * Read a hyperslab — `count` elements starting at element `offset`.
 * Useful for partial-spectrum reads.
 */
- (NSData *)readDataAtOffset:(NSUInteger)offset
                       count:(NSUInteger)count
                       error:(NSError **)error;

@end

#endif
