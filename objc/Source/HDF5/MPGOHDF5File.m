#import "MPGOHDF5File.h"
#import "MPGOHDF5Group.h"
#import "MPGOHDF5Errors.h"
#import <hdf5.h>
#import <sys/stat.h>
#import <pthread.h>

@implementation MPGOHDF5File
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
        if (error) *error = MPGOMakeError(MPGOErrorFileCreate,
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
        if (error) *error = MPGOMakeError(MPGOErrorFileNotFound,
            @"file not found: %@", path);
        return nil;
    }
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDWR, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorFileOpen,
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
        if (error) *error = MPGOMakeError(MPGOErrorFileNotFound,
            @"file not found: %@", path);
        return nil;
    }
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDONLY, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorFileOpen,
            @"H5Fopen RDONLY failed for %@", path);
        return nil;
    }
    return [[self alloc] initWithFileId:fid path:path];
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

- (MPGOHDF5Group *)rootGroup
{
    [self lockForReading];
    hid_t gid = H5Gopen2(_fileId, "/", H5P_DEFAULT);
    [self unlockForReading];
    if (gid < 0) return nil;
    return [[MPGOHDF5Group alloc] initWithGroupId:gid retainer:self];
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

- (MPGOHDF5File *)owningFile
{
    return self;
}

- (void)dealloc
{
    [self close];
    if (_lockInitOK) pthread_rwlock_destroy(&_rwlock);
}

@end
