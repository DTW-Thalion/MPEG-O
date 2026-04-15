#ifndef MPGO_HDF5_FILE_H
#define MPGO_HDF5_FILE_H

#import <Foundation/Foundation.h>

@class MPGOHDF5Group;

/**
 * Thin Cocoa wrapper around an HDF5 file handle (hid_t from H5Fcreate /
 * H5Fopen). The handle is closed in -dealloc; callers may also force an
 * early close via -close. Concurrent access from multiple threads is
 * undefined — match HDF5's serial threading model.
 */
@interface MPGOHDF5File : NSObject

@property (readonly, copy) NSString *path;

/** Create a new HDF5 file at path, truncating any existing file. */
+ (instancetype)createAtPath:(NSString *)path error:(NSError **)error;

/** Open an existing HDF5 file at path for read/write. */
+ (instancetype)openAtPath:(NSString *)path error:(NSError **)error;

/** Open an existing HDF5 file at path read-only. */
+ (instancetype)openReadOnlyAtPath:(NSString *)path error:(NSError **)error;

/** The root group ("/") of this file. Lazily constructed. */
- (MPGOHDF5Group *)rootGroup;

/** Close the file handle early. Idempotent. Returns NO on close failure. */
- (BOOL)close;

@end

#endif
