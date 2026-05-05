#ifndef TTIO_HDF5_COMPOUND_TYPE_H
#define TTIO_HDF5_COMPOUND_TYPE_H

#import <Foundation/Foundation.h>
#import <hdf5.h>

/**
 * <heading>TTIOHDF5CompoundType</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> HDF5/TTIOHDF5CompoundType.h</p>
 *
 * <p>Thin Objective-C wrapper around an HDF5 compound datatype
 * (<code>H5T_COMPOUND</code>). Supports ordinary native numeric
 * fields, variable-length string fields, and variable-length byte
 * fields. Owns its compound type id and every auxiliary type id it
 * allocated for VL members; all are released in <code>-close</code>
 * / <code>-dealloc</code>.</p>
 *
 * <p>Typical usage inside a writer:</p>
 *
 * <pre>
 *     TTIOHDF5CompoundType *t = [[TTIOHDF5CompoundType alloc]
 *                                  initWithSize:sizeof(my_rec_t)];
 *     [t addField:@"spectrum_ref"
 *            type:H5T_NATIVE_UINT32
 *          offset:HOFFSET(my_rec_t, spectrum_ref)];
 *     [t addVariableLengthStringFieldNamed:@"name"
 *                                  atOffset:HOFFSET(my_rec_t, name)];
 *     hid_t tid = t.typeId;
 *     ... H5Dcreate2(..., tid, ...) ...
 *     [t close];
 * </pre>
 *
 * <p><strong>API status:</strong> Stable.</p>
 */
@interface TTIOHDF5CompoundType : NSObject

/**
 * Designated initialiser.
 *
 * @param totalSize Byte size of the in-memory record.
 * @return An initialised compound type.
 */
- (instancetype)initWithSize:(size_t)totalSize;

/**
 * Inserts a native (non-VL) field at the given byte offset.
 *
 * @param name   Field name.
 * @param type   Native HDF5 type id (e.g.
 *               <code>H5T_NATIVE_UINT32</code>).
 * @param offset Byte offset of the field within the record.
 * @return <code>YES</code> on success.
 */
- (BOOL)addField:(NSString *)name
            type:(hid_t)type
          offset:(size_t)offset;

/**
 * Inserts a variable-length C-string field. Internally copies
 * <code>H5T_C_S1</code>, sets size to <code>H5T_VARIABLE</code>,
 * and retains the auxiliary type id for cleanup.
 *
 * @param name   Field name.
 * @param offset Byte offset of the <code>char *</code> within the
 *               record.
 * @return <code>YES</code> on success.
 */
- (BOOL)addVariableLengthStringFieldNamed:(NSString *)name
                                 atOffset:(size_t)offset;

/**
 * Inserts a variable-length byte-buffer field
 * (<code>H5Tvlen_create</code> on
 * <code>H5T_NATIVE_UCHAR</code>). On the wire each row is an
 * <code>hvl_t {size_t len; void *p;}</code>. The auxiliary type id
 * is retained for cleanup.
 *
 * @param name   Field name.
 * @param offset Byte offset of the <code>hvl_t</code> within the
 *               record.
 * @return <code>YES</code> on success.
 */
- (BOOL)addVariableLengthBytesFieldNamed:(NSString *)name
                                atOffset:(size_t)offset;

/** Constructed <code>H5T_COMPOUND</code> id; valid until
 *  <code>-close</code> is invoked. */
@property (readonly) hid_t typeId;

/** Byte size passed to <code>-initWithSize:</code>. */
@property (readonly) size_t totalSize;

/**
 * Releases the compound type and any auxiliary VL type ids.
 * Idempotent.
 */
- (void)close;

@end

#endif /* TTIO_HDF5_COMPOUND_TYPE_H */
