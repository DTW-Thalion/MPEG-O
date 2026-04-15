#ifndef MPGO_HDF5_GROUP_H
#define MPGO_HDF5_GROUP_H

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "ValueClasses/MPGOEnums.h"

@class MPGOHDF5Dataset;
@class MPGOHDF5Attribute;

/**
 * Thin wrapper around an HDF5 group handle. Created by
 * -[MPGOHDF5File rootGroup] or by another group's -createGroupNamed: / -openGroupNamed:.
 *
 * Non-owning: the parent file's lifetime is retained by every group derived
 * from it, so closing the file closes all groups transitively.
 */
@interface MPGOHDF5Group : NSObject

/** Internal initializer; not intended for external use. */
- (instancetype)initWithGroupId:(hid_t)gid retainer:(id)retainer;

/** The raw HDF5 group identifier. */
@property (readonly) hid_t groupId;

#pragma mark - Sub-groups

- (MPGOHDF5Group *)createGroupNamed:(NSString *)name error:(NSError **)error;
- (MPGOHDF5Group *)openGroupNamed:(NSString *)name error:(NSError **)error;
- (BOOL)hasChildNamed:(NSString *)name;

#pragma mark - Datasets

/**
 * Create a new dataset under this group with the given precision, length,
 * chunked storage, and zlib compression level (0 = none, 1–9 = deflate level).
 * Pass chunkSize == 0 to use a single contiguous chunk.
 */
- (MPGOHDF5Dataset *)createDatasetNamed:(NSString *)name
                              precision:(MPGOPrecision)precision
                                 length:(NSUInteger)length
                              chunkSize:(NSUInteger)chunkSize
                       compressionLevel:(int)compressionLevel
                                  error:(NSError **)error;

- (MPGOHDF5Dataset *)openDatasetNamed:(NSString *)name error:(NSError **)error;

#pragma mark - Attributes

- (BOOL)setStringAttribute:(NSString *)name
                     value:(NSString *)value
                     error:(NSError **)error;

- (NSString *)stringAttributeNamed:(NSString *)name error:(NSError **)error;

- (BOOL)setIntegerAttribute:(NSString *)name
                      value:(int64_t)value
                      error:(NSError **)error;

- (int64_t)integerAttributeNamed:(NSString *)name
                          exists:(BOOL *)outExists
                           error:(NSError **)error;

- (BOOL)hasAttributeNamed:(NSString *)name;

@end

#endif
