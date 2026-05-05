#ifndef TTIO_HDF5_GROUP_H
#define TTIO_HDF5_GROUP_H

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOHDF5Dataset;
@class TTIOHDF5Attribute;

/**
 * <heading>TTIOHDF5Group</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> HDF5/TTIOHDF5Group.h</p>
 *
 * <p>Thin wrapper around an HDF5 group handle. Created by
 * <code>-[TTIOHDF5File rootGroup]</code> or by another group's
 * <code>-createGroupNamed:error:</code> /
 * <code>-openGroupNamed:error:</code>.</p>
 *
 * <p>Non-owning: the parent file's lifetime is retained by every
 * group derived from it, so closing the file closes all groups
 * transitively.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 */
@interface TTIOHDF5Group : NSObject

/**
 * Internal initialiser used by <code>TTIOHDF5File</code> and parent
 * groups. Not intended for external use.
 *
 * @param gid      HDF5 group id obtained from
 *                 <code>H5Gcreate2</code> / <code>H5Gopen2</code>.
 * @param retainer Object whose lifetime keeps the parent file
 *                 alive.
 * @return An initialised group.
 */
- (instancetype)initWithGroupId:(hid_t)gid retainer:(id)retainer;

/** Raw HDF5 group identifier. */
@property (readonly) hid_t groupId;

#pragma mark - Sub-groups

/**
 * Creates a child group.
 *
 * @param name  Child name.
 * @param error Out-parameter populated on failure.
 * @return The new group, or <code>nil</code> on failure.
 */
- (TTIOHDF5Group *)createGroupNamed:(NSString *)name error:(NSError **)error;

/**
 * Opens an existing child group.
 *
 * @param name  Child name.
 * @param error Out-parameter populated on failure.
 * @return The opened group, or <code>nil</code> on failure.
 */
- (TTIOHDF5Group *)openGroupNamed:(NSString *)name error:(NSError **)error;

/**
 * @param name Child name.
 * @return <code>YES</code> if a child group or dataset with the
 *         given name exists.
 */
- (BOOL)hasChildNamed:(NSString *)name;

/**
 * Deletes the named link (child group or dataset). No-op when the
 * child is absent.
 *
 * @param name  Child name.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error;

#pragma mark - Datasets

/**
 * Creates a new dataset under this group with chunked storage and
 * zlib compression.
 *
 * @param name             Dataset name.
 * @param precision        Element precision.
 * @param length           Element count.
 * @param chunkSize        Chunk size in elements; pass <code>0</code>
 *                         to use a single contiguous chunk.
 * @param compressionLevel zlib level (<code>0</code> = none,
 *                         <code>1</code>-<code>9</code> = deflate).
 * @param error            Out-parameter populated on failure.
 * @return The new dataset, or <code>nil</code> on failure.
 */
- (TTIOHDF5Dataset *)createDatasetNamed:(NSString *)name
                              precision:(TTIOPrecision)precision
                                 length:(NSUInteger)length
                              chunkSize:(NSUInteger)chunkSize
                       compressionLevel:(int)compressionLevel
                                  error:(NSError **)error;

/**
 * Creates a dataset with an explicit
 * <code>TTIOCompression</code> choice. Honours
 * <code>compressionLevel</code> for zlib (<code>0</code>-<code>9</code>);
 * LZ4 ignores the level.
 *
 * <p><code>TTIOCompressionLZ4</code> requires the LZ4 plugin to be
 * loadable at runtime; if <code>H5Zfilter_avail(32004)</code> is
 * false the call fails with <code>TTIOErrorDatasetCreate</code> and
 * a descriptive error message.</p>
 *
 * @param name             Dataset name.
 * @param precision        Element precision.
 * @param length           Element count.
 * @param chunkSize        Chunk size in elements; pass <code>0</code>
 *                         for contiguous storage.
 * @param compression      Compression algorithm enum value.
 * @param compressionLevel zlib level (ignored for LZ4 / NONE).
 * @param error            Out-parameter populated on failure.
 * @return The new dataset, or <code>nil</code> on failure.
 */
- (TTIOHDF5Dataset *)createDatasetNamed:(NSString *)name
                              precision:(TTIOPrecision)precision
                                 length:(NSUInteger)length
                              chunkSize:(NSUInteger)chunkSize
                            compression:(TTIOCompression)compression
                       compressionLevel:(int)compressionLevel
                                  error:(NSError **)error;

/**
 * Opens an existing dataset.
 *
 * @param name  Dataset name.
 * @param error Out-parameter populated on failure.
 * @return The opened dataset, or <code>nil</code> on failure.
 */
- (TTIOHDF5Dataset *)openDatasetNamed:(NSString *)name error:(NSError **)error;

#pragma mark - Attributes

/**
 * Sets a string attribute on this group, creating it if absent.
 *
 * @param name  Attribute name.
 * @param value String value.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)setStringAttribute:(NSString *)name
                     value:(NSString *)value
                     error:(NSError **)error;

/**
 * Reads a string attribute from this group.
 *
 * @param name  Attribute name.
 * @param error Out-parameter populated on failure (including
 *              attribute-absent).
 * @return The attribute value, or <code>nil</code> on failure.
 */
- (NSString *)stringAttributeNamed:(NSString *)name error:(NSError **)error;

/**
 * Sets an int64 attribute on this group, creating it if absent.
 *
 * @param name  Attribute name.
 * @param value int64 value.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)setIntegerAttribute:(NSString *)name
                      value:(int64_t)value
                      error:(NSError **)error;

/**
 * Reads an int64 attribute from this group.
 *
 * @param name      Attribute name.
 * @param outExists Optional out-parameter set to <code>YES</code>
 *                  if the attribute exists, <code>NO</code> otherwise.
 *                  When <code>NO</code> the return value is
 *                  <code>0</code> and <code>error</code> is not
 *                  populated.
 * @param error     Out-parameter populated on read-time failure.
 * @return The attribute value (<code>0</code> if absent).
 */
- (int64_t)integerAttributeNamed:(NSString *)name
                          exists:(BOOL *)outExists
                           error:(NSError **)error;

/**
 * @param name Attribute name.
 * @return <code>YES</code> if the attribute exists on this group.
 */
- (BOOL)hasAttributeNamed:(NSString *)name;

/**
 * Deletes the named attribute. No-op when the attribute is absent.
 *
 * @param name  Attribute name.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error;

/** @return Alphabetically-ordered names of every attribute on this
 *          group. */
- (NSArray<NSString *> *)attributeNames;

/** @return Names of every link (group or dataset) directly under
 *          this group. */
- (NSArray<NSString *> *)childNames;

/** @return Last-path-segment name, or <code>"/"</code> for root. */
- (NSString *)groupName;

@end

#endif
