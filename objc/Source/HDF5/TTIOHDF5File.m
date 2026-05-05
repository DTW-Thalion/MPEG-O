/*
 * TTIOHDF5File.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOHDF5File
 * Inherits From: NSObject
 * Declared In:   HDF5/TTIOHDF5File.h
 *
 * Thin Cocoa wrapper around an HDF5 file handle. Owns a
 * pthread_rwlock_t so that derived TTIOHDF5Group / TTIOHDF5Dataset
 * objects can serialise concurrent access. Supports filesystem
 * paths and S3 URLs (via libhdf5's ROS3 VFD).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOHDF5File.h"
#import "TTIOHDF5Group.h"
#import "TTIOHDF5Errors.h"
#import <hdf5.h>
#import <sys/stat.h>
#import <pthread.h>

@implementation TTIOHDF5File
{
    hid_t            _fileId;
    BOOL             _closed;
    pthread_rwlock_t _rwlock;
    BOOL             _lockInitOK;
    BOOL             _libThreadSafe;  // libhdf5 reports H5is_library_threadsafe
}

+ (instancetype)createAtPath:(NSString *)path error:(NSError **)error
{
    NSParameterAssert(path != nil);
    hid_t fid = H5Fcreate([path fileSystemRepresentation],
                          H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileCreate,
            @"H5Fcreate failed for %@", path);
        return nil;
    }
    return [[self alloc] initWithFileId:fid path:path];
}

+ (instancetype)openAtPath:(NSString *)path error:(NSError **)error
{
    NSParameterAssert(path != nil);
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileNotFound,
            @"file not found: %@", path);
        return nil;
    }
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDWR, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"H5Fopen failed for %@", path);
        return nil;
    }
    return [[self alloc] initWithFileId:fid path:path];
}

+ (instancetype)openReadOnlyAtPath:(NSString *)path error:(NSError **)error
{
    NSParameterAssert(path != nil);
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileNotFound,
            @"file not found: %@", path);
        return nil;
    }
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDONLY, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"H5Fopen RDONLY failed for %@", path);
        return nil;
    }
    return [[self alloc] initWithFileId:fid path:path];
}

+ (BOOL)isS3Supported
{
#ifdef H5_HAVE_ROS3_VFD
    return YES;
#else
    // Probe at runtime — apt's libhdf5 exports H5Pset_fapl_ros3 even
    // when the compile-time macro isn't exposed in the header we ship
    // against. Call H5Zfilter_avail on a sentinel; safer is to try to
    // set the ROS3 fapl on a transient plist and observe.
    hid_t fapl = H5Pcreate(H5P_FILE_ACCESS);
    if (fapl < 0) return NO;
    H5FD_ros3_fapl_t cfg = { .version = H5FD_CURR_ROS3_FAPL_T_VERSION,
                              .authenticate = false };
    herr_t rc = H5Pset_fapl_ros3(fapl, &cfg);
    H5Pclose(fapl);
    return rc >= 0 ? YES : NO;
#endif
}

static NSString *translateS3URL(NSString *url, NSString *region)
{
    // s3://bucket/key  →  https://bucket.s3.<region>.amazonaws.com/key
    // Any other scheme is passed through unchanged.
    if (![url hasPrefix:@"s3://"]) return url;
    NSString *rest = [url substringFromIndex:5];
    NSRange slash = [rest rangeOfString:@"/"];
    if (slash.location == NSNotFound) {
        return [NSString stringWithFormat:@"https://%@.s3.%@.amazonaws.com/",
                rest, region];
    }
    NSString *bucket = [rest substringToIndex:slash.location];
    NSString *key    = [rest substringFromIndex:slash.location + 1];
    return [NSString stringWithFormat:@"https://%@.s3.%@.amazonaws.com/%@",
            bucket, region, key];
}

+ (instancetype)openS3URL:(NSString *)url
                    region:(NSString *)awsRegion
              accessKeyId:(NSString *)accessKeyId
          secretAccessKey:(NSString *)secretAccessKey
             sessionToken:(NSString *)sessionToken
                     error:(NSError **)error
{
    NSParameterAssert(url != nil);

    if (![self isS3Supported]) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"libhdf5 was built without ROS3 VFD support; rebuild "
            @"libhdf5 with --with-ros3-vfd (or install a distribution "
            @"build that includes it)");
        return nil;
    }

    if (awsRegion.length == 0) {
        const char *env = getenv("AWS_REGION");
        awsRegion = env ? [NSString stringWithUTF8String:env] : @"us-east-1";
    }
    NSString *httpsURL = translateS3URL(url, awsRegion);

    hid_t fapl = H5Pcreate(H5P_FILE_ACCESS);
    if (fapl < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"H5Pcreate(H5P_FILE_ACCESS) failed");
        return nil;
    }

    H5FD_ros3_fapl_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.version = H5FD_CURR_ROS3_FAPL_T_VERSION;
    cfg.authenticate = (accessKeyId.length > 0 && secretAccessKey.length > 0);
    if (cfg.authenticate) {
        strncpy(cfg.aws_region, [awsRegion UTF8String],
                sizeof(cfg.aws_region) - 1);
        strncpy(cfg.secret_id, [accessKeyId UTF8String],
                sizeof(cfg.secret_id) - 1);
        strncpy(cfg.secret_key, [secretAccessKey UTF8String],
                sizeof(cfg.secret_key) - 1);
    }

    if (H5Pset_fapl_ros3(fapl, &cfg) < 0) {
        H5Pclose(fapl);
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"H5Pset_fapl_ros3 failed for %@", url);
        return nil;
    }

    // Session token requires the newer ros3 fapl (v2). Apply it only
    // when the caller provides one; older libhdf5 versions lack the
    // helper and will skip the call.
#if defined(H5_HAVE_ROS3_VFD) && defined(H5FD_ROS3_MAX_SECRET_TOK_LEN)
    if (sessionToken.length > 0) {
        H5Pset_fapl_ros3_token(fapl, [sessionToken UTF8String]);
    }
#else
    (void)sessionToken;
#endif

    hid_t fid = H5Fopen([httpsURL UTF8String], H5F_ACC_RDONLY, fapl);
    H5Pclose(fapl);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"H5Fopen(ROS3) failed for %@ "
            @"(check bucket/key/region/credentials)", httpsURL);
        return nil;
    }
    return [[self alloc] initWithFileId:fid path:httpsURL];
}

- (instancetype)initWithFileId:(hid_t)fid path:(NSString *)path
{
    self = [super init];
    if (self) {
        _fileId = fid;
        _path = [path copy];
        _closed = NO;
        _lockInitOK = (pthread_rwlock_init(&_rwlock, NULL) == 0);

        // Probe libhdf5 once per file. If false, readers fall back to the
        // writer (exclusive) lock so we never call into a non-threadsafe
        // libhdf5 from two threads at once. -isThreadSafe reports false in
        // that case so callers know they're in degraded mode.
        hbool_t ts = 0;
        if (H5is_library_threadsafe(&ts) < 0) ts = 0;
        _libThreadSafe = (ts != 0);
    }
    return self;
}

- (TTIOHDF5Group *)rootGroup
{
    [self lockForReading];
    hid_t gid = H5Gopen2(_fileId, "/", H5P_DEFAULT);
    [self unlockForReading];
    if (gid < 0) return nil;
    return [[TTIOHDF5Group alloc] initWithGroupId:gid retainer:self];
}

- (BOOL)close
{
    if (_closed) return YES;
    herr_t status = H5Fclose(_fileId);
    _closed = YES;
    return status >= 0;
}

#pragma mark - Thread safety

- (BOOL)isThreadSafe
{
    return (_libThreadSafe && _lockInitOK) ? YES : NO;
}

- (void)lockForReading
{
    if (!_lockInitOK) return;
    // Degraded mode: serialise readers too when libhdf5 isn't threadsafe.
    if (_libThreadSafe) pthread_rwlock_rdlock(&_rwlock);
    else                pthread_rwlock_wrlock(&_rwlock);
}

- (void)unlockForReading
{
    if (_lockInitOK) pthread_rwlock_unlock(&_rwlock);
}

- (void)lockForWriting
{
    if (_lockInitOK) pthread_rwlock_wrlock(&_rwlock);
}

- (void)unlockForWriting
{
    if (_lockInitOK) pthread_rwlock_unlock(&_rwlock);
}

- (TTIOHDF5File *)owningFile
{
    return self;
}

- (void)dealloc
{
    [self close];
    if (_lockInitOK) pthread_rwlock_destroy(&_rwlock);
}

@end
