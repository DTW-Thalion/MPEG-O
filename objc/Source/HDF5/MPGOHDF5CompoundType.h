#ifndef MPGO_HDF5_COMPOUND_TYPE_H
#define MPGO_HDF5_COMPOUND_TYPE_H

#import <Foundation/Foundation.h>
#import <hdf5.h>

/**
 * Thin Objective-C wrapper around an HDF5 compound datatype (H5T_COMPOUND).
 * Supports ordinary native numeric fields plus variable-length string
 * fields. Owns its compound type id and every auxiliary type id it
 * allocated for VL strings; all are released in -close / -dealloc.
 *
 * Typical usage inside a writer:
 *
 *     MPGOHDF5CompoundType *t = [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(my_rec_t)];
 *     [t addField:@"spectrum_ref"
 *            type:H5T_NATIVE_UINT32
 *          offset:HOFFSET(my_rec_t, spectrum_ref)];
 *     [t addVariableLengthStringFieldNamed:@"name"
 *                                   atOffset:HOFFSET(my_rec_t, name)];
 *     hid_t tid = t.typeId;
 *     ... H5Dcreate2(..., tid, ...) ...
 *     [t close];
 */
@interface MPGOHDF5CompoundType : NSObject

- (instancetype)initWithSize:(size_t)totalSize;

/** Insert a native (non-VL) field at the given byte offset. */
- (BOOL)addField:(NSString *)name
            type:(hid_t)type
          offset:(size_t)offset;

/** Insert a variable-length C string field. Internally copies
 *  H5T_C_S1, sets size to H5T_VARIABLE, and retains the aux type
 *  id for cleanup. */
- (BOOL)addVariableLengthStringFieldNamed:(NSString *)name
                                  atOffset:(size_t)offset;

/** The constructed H5T_COMPOUND id. Valid until -close is invoked. */
@property (readonly) hid_t typeId;

/** Byte size passed to init. */
@property (readonly) size_t totalSize;

/** Release the compound type and any auxiliary VL string types.
 *  Idempotent. */
- (void)close;

@end

#endif /* MPGO_HDF5_COMPOUND_TYPE_H */
