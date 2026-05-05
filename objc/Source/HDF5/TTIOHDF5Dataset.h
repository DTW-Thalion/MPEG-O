#ifndef TTIO_HDF5_DATASET_H
#define TTIO_HDF5_DATASET_H

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "ValueClasses/TTIOEnums.h"

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> HDF5/TTIOHDF5Dataset.h</p>
 *
 * <p>Thin wrapper around a 1-D HDF5 dataset. Owns its dataset id
 * and (for compound types) the type id; both are released in
 * <code>-dealloc</code>.</p>
 *
 * <p>Datasets are created with a definite element count and
 * precision; the shape cannot be resized after creation.
 * Hyperslab reads (<code>-readDataAtOffset:count:error:</code>)
 * support partial-spectrum access without materialising the entire
 * dataset.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 */
@interface TTIOHDF5Dataset : NSObject

/**
 * Internal initialiser used by <code>TTIOHDF5Group</code>. Not
 * intended for external use.
 *
 * @param did       HDF5 dataset id obtained from
 *                  <code>H5Dcreate2</code> / <code>H5Dopen2</code>.
 * @param precision Element precision.
 * @param length    Element count.
 * @param retainer  Object whose lifetime keeps the parent file
 *                  alive (normally a <code>TTIOHDF5Group</code>).
 * @return An initialised dataset.
 */
- (instancetype)initWithDatasetId:(hid_t)did
                        precision:(TTIOPrecision)precision
                           length:(NSUInteger)length
                         retainer:(id)retainer;

/** Raw HDF5 dataset id. */
@property (readonly) hid_t datasetId;

/** Element precision. */
@property (readonly) TTIOPrecision precision;

/** Element count. */
@property (readonly) NSUInteger length;

/**
 * Writes all elements.
 *
 * @param data  Buffer; <code>data.length</code> must equal
 *              <code>length * elementSize(precision)</code>.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)writeData:(NSData *)data error:(NSError **)error;

/**
 * Reads all elements.
 *
 * @param error Out-parameter populated on failure.
 * @return Buffer of <code>length * elementSize(precision)</code>
 *         bytes, or <code>nil</code> on failure.
 */
- (NSData *)readDataWithError:(NSError **)error;

/**
 * Reads a hyperslab.
 *
 * @param offset Element offset of the first element to read.
 * @param count  Number of elements to read.
 * @param error  Out-parameter populated on failure.
 * @return Buffer of <code>count * elementSize(precision)</code>
 *         bytes, or <code>nil</code> on failure.
 */
- (NSData *)readDataAtOffset:(NSUInteger)offset
                       count:(NSUInteger)count
                       error:(NSError **)error;

@end

#endif
