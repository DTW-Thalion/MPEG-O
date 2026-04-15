#import "MPGOHDF5File.h"
#import "MPGOHDF5Group.h"
#import "MPGOHDF5Errors.h"
#import <hdf5.h>
#import <sys/stat.h>

@implementation MPGOHDF5File
{
    hid_t  _fileId;
    BOOL   _closed;
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
    }
    return self;
}

- (MPGOHDF5Group *)rootGroup
{
    hid_t gid = H5Gopen2(_fileId, "/", H5P_DEFAULT);
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

- (void)dealloc
{
    [self close];
}

@end
