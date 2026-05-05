#ifndef TTIO_HDF5_FILE_H
#define TTIO_HDF5_FILE_H

#import <Foundation/Foundation.h>

@class TTIOHDF5Group;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> HDF5/TTIOHDF5File.h</p>
 *
 * <p>Thin Cocoa wrapper around an HDF5 file handle (<code>hid_t</code>
 * obtained from <code>H5Fcreate</code> / <code>H5Fopen</code>). The
 * handle is closed in <code>-dealloc</code>; callers may also force
 * an early close via <code>-close</code>.</p>
 *
 * <p><strong>Thread safety.</strong> Each <code>TTIOHDF5File</code>
 * owns a <code>pthread_rwlock_t</code> that serialises access from
 * <code>TTIOHDF5Group</code> and <code>TTIOHDF5Dataset</code>
 * instances derived from it. Readers do not block readers; writers
 * are exclusive. The wrapper lock provides call-site invariant
 * protection; the underlying <code>libhdf5</code> must also be
 * compiled with <code>--enable-threadsafe</code> (check
 * <code>-isThreadSafe</code> at runtime).</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 */
@interface TTIOHDF5File : NSObject

/** Filesystem path the handle was opened against, or
 *  <code>nil</code> for in-memory / cloud handles. */
@property (readonly, copy) NSString *path;

/**
 * Creates a new HDF5 file at the given path, truncating any
 * existing file.
 *
 * @param path  Filesystem path.
 * @param error Out-parameter populated on failure.
 * @return An open file, or <code>nil</code> on failure.
 */
+ (instancetype)createAtPath:(NSString *)path error:(NSError **)error;

/**
 * Opens an existing HDF5 file at the given path for read/write.
 *
 * @param path  Filesystem path.
 * @param error Out-parameter populated on failure.
 * @return An open file, or <code>nil</code> on failure.
 */
+ (instancetype)openAtPath:(NSString *)path error:(NSError **)error;

/**
 * Opens an existing HDF5 file at the given path read-only.
 *
 * @param path  Filesystem path.
 * @param error Out-parameter populated on failure.
 * @return An open file, or <code>nil</code> on failure.
 */
+ (instancetype)openReadOnlyAtPath:(NSString *)path error:(NSError **)error;

/**
 * Opens a remote .tio file hosted on S3 (or any S3-compatible
 * endpoint such as MinIO or LocalStack) read-only via libhdf5's
 * ROS3 VFD.
 *
 * <p>Requires the linked libhdf5 to have been built with
 * <code>--with-ros3-vfd</code>. Probe at runtime with
 * <code>+isS3Supported</code>; on a build without ROS3 the call
 * fails with <code>TTIOErrorFileOpen</code>.</p>
 *
 * <p><strong>Security.</strong> Credentials are passed through to
 * libhdf5 which stores them in the file-access property list for
 * the lifetime of the opened handle. Do not pass credentials a
 * caller would not otherwise feel comfortable exposing to the
 * HDF5 process.</p>
 *
 * @param url             S3 URL in canonical form
 *                        (<code>s3://bucket/key</code>) or
 *                        virtual-hosted-style HTTPS
 *                        (<code>https://bucket.s3.region.amazonaws.com/key</code>).
 *                        The canonical form is translated to a
 *                        region-aware HTTPS URL internally.
 * @param awsRegion       e.g. <code>@"us-east-1"</code>. Pass
 *                        <code>nil</code> to fall back to the
 *                        <code>AWS_REGION</code> environment
 *                        variable or <code>us-east-1</code>.
 * @param accessKeyId     AWS access key; pass <code>nil</code> for
 *                        anonymous (public bucket) access.
 * @param secretAccessKey AWS secret; pass <code>nil</code> for
 *                        anonymous access.
 * @param sessionToken    Optional STS session token; pass
 *                        <code>nil</code> if not using temporary
 *                        credentials.
 * @param error           Out-parameter populated on failure.
 * @return An open file, or <code>nil</code> on failure.
 */
+ (instancetype)openS3URL:(NSString *)url
                   region:(NSString *)awsRegion
              accessKeyId:(NSString *)accessKeyId
          secretAccessKey:(NSString *)secretAccessKey
             sessionToken:(NSString *)sessionToken
                    error:(NSError **)error;

/**
 * @return <code>YES</code> if the linked libhdf5 was built with
 *         ROS3 VFD support; <code>NO</code> means
 *         <code>+openS3URL:</code> will fail with
 *         <code>TTIOErrorFileOpen</code>.
 */
+ (BOOL)isS3Supported;

/**
 * @return The root group ("/") of this file. Lazily constructed.
 */
- (TTIOHDF5Group *)rootGroup;

/**
 * Closes the file handle early.
 *
 * @return <code>YES</code> on success. Idempotent.
 */
- (BOOL)close;

#pragma mark - Thread safety

/**
 * @return <code>YES</code> if both (a) the linked libhdf5 reports
 *         <code>H5is_library_threadsafe()</code> and (b) this
 *         file's wrapper rwlock initialised successfully. When
 *         <code>NO</code>, callers must serialise access externally;
 *         concurrent use is undefined.
 */
- (BOOL)isThreadSafe;

/** Acquires the wrapper's read (shared) lock. Multiple readers may
 *  hold it concurrently. Must be paired with
 *  <code>-unlockForReading</code>. */
- (void)lockForReading;

/** Releases the wrapper's read lock. */
- (void)unlockForReading;

/** Acquires the wrapper's write (exclusive) lock. Blocks readers
 *  and other writers. Must be paired with
 *  <code>-unlockForWriting</code>. */
- (void)lockForWriting;

/** Releases the wrapper's write lock. */
- (void)unlockForWriting;

/**
 * @return The owning file by walking the retainer chain.
 *         <code>TTIOHDF5File</code> returns <code>self</code>.
 */
- (TTIOHDF5File *)owningFile;

@end

#endif
