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

/**
 * Open a remote .mpgo file hosted on S3 (or any S3-compatible endpoint
 * — MinIO, LocalStack, etc.) read-only via libhdf5's ROS3 VFD.
 *
 * WORKPLAN v0.3 deferred follow-up (M20). Requires libhdf5 to have
 * been built with --with-ros3-vfd (apt's libhdf5 ships it enabled;
 * custom builds may not — use +isS3Supported to probe at runtime).
 *
 * @param url S3 URL in either canonical form (``s3://bucket/key``) or
 *            virtual-hosted style HTTPS (``https://bucket.s3.region.amazonaws.com/key``).
 *            The canonical form is translated to a region-aware HTTPS URL
 *            internally.
 * @param awsRegion e.g. ``@"us-east-1"``. Pass nil to fall back to the
 *                  ``AWS_REGION`` environment variable or ``us-east-1``.
 * @param accessKeyId AWS access key; pass nil for anonymous (public
 *                    bucket) access. Prefer the ``AWS_ACCESS_KEY_ID``
 *                    env var when building credentials at deploy time.
 * @param secretAccessKey AWS secret; pass nil for anonymous access.
 * @param sessionToken  Optional STS session token; pass nil if not using
 *                      temporary credentials.
 * @param error populated on failure.
 *
 * Security: credentials are passed through as-is to libhdf5 which
 * stores them in the file-access property list for the lifetime of
 * the opened handle. Do not pass credentials a caller would not
 * otherwise feel comfortable exposing to the HDF5 process.
 */
+ (instancetype)openS3URL:(NSString *)url
                    region:(NSString *)awsRegion
              accessKeyId:(NSString *)accessKeyId
          secretAccessKey:(NSString *)secretAccessKey
             sessionToken:(NSString *)sessionToken
                     error:(NSError **)error;

/** Returns YES if the linked libhdf5 was built with ROS3 VFD support.
 *  NO means +openS3URL: will fail with MPGOErrorFileOpen and callers
 *  should fall back to the download-then-open path. */
+ (BOOL)isS3Supported;

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
