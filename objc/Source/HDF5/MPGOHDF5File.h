#ifndef MPGO_HDF5_FILE_H
#define MPGO_HDF5_FILE_H

#import <Foundation/Foundation.h>

@class MPGOHDF5Group;

/**
 * Thin Cocoa wrapper around an HDF5 file handle (hid_t from H5Fcreate /
 * H5Fopen). The handle is closed in -dealloc; callers may also force an
 * early close via -close.
 *
 * M23 thread-safety model:
 *   Each MPGOHDF5File owns a pthread_rwlock_t that serialises access from
 *   MPGOHDF5Group and MPGOHDF5Dataset instances derived from it. Readers do
 *   not block readers; writers are exclusive. The wrapper lock provides
 *   call-site invariant protection; the HDF5 library itself must also be
 *   compiled with --enable-threadsafe (check -isThreadSafe at runtime).
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

#pragma mark - Thread safety (M23)

/**
 * Returns YES iff both (a) the linked libhdf5 reports H5is_library_threadsafe()
 * and (b) this file's wrapper rwlock initialised successfully. When NO, callers
 * must serialise access externally; concurrent use is undefined.
 */
- (BOOL)isThreadSafe;

/** Acquire the wrapper's read (shared) lock. Multiple readers may hold it
 *  concurrently. Must be paired with -unlockForReading. */
- (void)lockForReading;
- (void)unlockForReading;

/** Acquire the wrapper's write (exclusive) lock. Blocks readers and other
 *  writers. Must be paired with -unlockForWriting. */
- (void)lockForWriting;
- (void)unlockForWriting;

/** Walks the retainer chain to the owning file. MPGOHDF5File returns self. */
- (MPGOHDF5File *)owningFile;

@end

#endif
