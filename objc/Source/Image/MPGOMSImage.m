#import "MPGOMSImage.h"
#import "HDF5/MPGOHDF5Errors.h"
#import <hdf5.h>
#import <sys/stat.h>

@implementation MPGOMSImage

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
{
    NSParameterAssert(cube.length == width * height * spectralPoints * sizeof(double));
    self = [super init];
    if (self) {
        _width          = width;
        _height         = height;
        _spectralPoints = spectralPoints;
        _tileSize       = tileSize > 0 ? tileSize : 32;
        _cube           = [cube copy];
    }
    return self;
}

#pragma mark - Write

- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error
{
    hid_t fid = H5Fcreate([path fileSystemRepresentation],
                          H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorFileCreate,
            @"H5Fcreate failed for %@", path);
        return NO;
    }

    hid_t imageGroup = H5Gcreate2(fid, "image_cube", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (imageGroup < 0) {
        H5Fclose(fid);
        if (error) *error = MPGOMakeError(MPGOErrorGroupCreate, @"H5Gcreate2 image_cube failed");
        return NO;
    }

    // Shape: [height, width, spectralPoints]; chunks tile-aligned.
    hsize_t dims[3]  = { (hsize_t)_height, (hsize_t)_width, (hsize_t)_spectralPoints };
    hsize_t chunk[3] = { (hsize_t)MIN(_tileSize, _height),
                         (hsize_t)MIN(_tileSize, _width),
                         (hsize_t)_spectralPoints };

    hid_t space = H5Screate_simple(3, dims, NULL);
    hid_t plist = H5Pcreate(H5P_DATASET_CREATE);
    H5Pset_chunk(plist, 3, chunk);
    H5Pset_deflate(plist, 6);

    hid_t did = H5Dcreate2(imageGroup, "intensity",
                           H5T_NATIVE_DOUBLE, space,
                           H5P_DEFAULT, plist, H5P_DEFAULT);
    if (did < 0) {
        H5Pclose(plist); H5Sclose(space); H5Gclose(imageGroup); H5Fclose(fid);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate, @"H5Dcreate2 intensity failed");
        return NO;
    }

    herr_t s = H5Dwrite(did, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, _cube.bytes);
    if (s < 0) {
        H5Dclose(did); H5Pclose(plist); H5Sclose(space); H5Gclose(imageGroup); H5Fclose(fid);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite, @"H5Dwrite intensity failed");
        return NO;
    }

    // Shape attrs for round-trip.
    hid_t scalar = H5Screate(H5S_SCALAR);
    hid_t a;
    int64_t v;
    a = H5Acreate2(imageGroup, "width", H5T_NATIVE_INT64, scalar, H5P_DEFAULT, H5P_DEFAULT);
    v = (int64_t)_width;          H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a);
    a = H5Acreate2(imageGroup, "height", H5T_NATIVE_INT64, scalar, H5P_DEFAULT, H5P_DEFAULT);
    v = (int64_t)_height;         H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a);
    a = H5Acreate2(imageGroup, "spectral_points", H5T_NATIVE_INT64, scalar, H5P_DEFAULT, H5P_DEFAULT);
    v = (int64_t)_spectralPoints; H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a);
    a = H5Acreate2(imageGroup, "tile_size", H5T_NATIVE_INT64, scalar, H5P_DEFAULT, H5P_DEFAULT);
    v = (int64_t)_tileSize;       H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a);
    H5Sclose(scalar);

    H5Dclose(did); H5Pclose(plist); H5Sclose(space); H5Gclose(imageGroup); H5Fclose(fid);
    return YES;
}

#pragma mark - Read

+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error
{
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0) {
        if (error) *error = MPGOMakeError(MPGOErrorFileNotFound, @"file not found: %@", path);
        return nil;
    }
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDONLY, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorFileOpen, @"H5Fopen failed for %@", path);
        return nil;
    }

    hid_t imageGroup = H5Gopen2(fid, "image_cube", H5P_DEFAULT);
    if (imageGroup < 0) {
        H5Fclose(fid);
        if (error) *error = MPGOMakeError(MPGOErrorGroupOpen, @"image_cube not found");
        return nil;
    }

    int64_t width = 0, height = 0, sp = 0, ts = 0;
    hid_t a;
    a = H5Aopen(imageGroup, "width",  H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &width);  H5Aclose(a);
    a = H5Aopen(imageGroup, "height", H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &height); H5Aclose(a);
    a = H5Aopen(imageGroup, "spectral_points", H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &sp); H5Aclose(a);
    a = H5Aopen(imageGroup, "tile_size",       H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &ts); H5Aclose(a);

    hid_t did = H5Dopen2(imageGroup, "intensity", H5P_DEFAULT);
    NSUInteger total = (NSUInteger)(width * height * sp);
    NSMutableData *cube = [NSMutableData dataWithLength:total * sizeof(double)];
    herr_t s = H5Dread(did, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, cube.mutableBytes);
    H5Dclose(did); H5Gclose(imageGroup); H5Fclose(fid);

    if (s < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead, @"intensity H5Dread failed");
        return nil;
    }
    return [[self alloc] initWithWidth:(NSUInteger)width
                                height:(NSUInteger)height
                        spectralPoints:(NSUInteger)sp
                              tileSize:(NSUInteger)ts
                                  cube:cube];
}

#pragma mark - Tile read

+ (NSData *)readTileFromFilePath:(NSString *)path
                            atX:(NSUInteger)x
                              y:(NSUInteger)y
                          width:(NSUInteger)tw
                         height:(NSUInteger)th
                          error:(NSError **)error
{
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDONLY, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorFileOpen, @"H5Fopen failed");
        return nil;
    }
    hid_t imageGroup = H5Gopen2(fid, "image_cube", H5P_DEFAULT);
    if (imageGroup < 0) {
        H5Fclose(fid);
        if (error) *error = MPGOMakeError(MPGOErrorGroupOpen, @"image_cube missing");
        return nil;
    }
    int64_t sp = 0;
    hid_t a = H5Aopen(imageGroup, "spectral_points", H5P_DEFAULT);
    H5Aread(a, H5T_NATIVE_INT64, &sp); H5Aclose(a);

    hid_t did = H5Dopen2(imageGroup, "intensity", H5P_DEFAULT);
    if (did < 0) {
        H5Gclose(imageGroup); H5Fclose(fid);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetOpen, @"intensity dataset missing");
        return nil;
    }

    hid_t fspace = H5Dget_space(did);
    hsize_t off[3]   = { (hsize_t)y,  (hsize_t)x,  0 };
    hsize_t cnt[3]   = { (hsize_t)th, (hsize_t)tw, (hsize_t)sp };
    H5Sselect_hyperslab(fspace, H5S_SELECT_SET, off, NULL, cnt, NULL);

    hid_t mspace = H5Screate_simple(3, cnt, NULL);

    NSUInteger total = (NSUInteger)(th * tw * sp);
    NSMutableData *out = [NSMutableData dataWithLength:total * sizeof(double)];
    herr_t s = H5Dread(did, H5T_NATIVE_DOUBLE, mspace, fspace, H5P_DEFAULT, out.mutableBytes);

    H5Sclose(mspace); H5Sclose(fspace); H5Dclose(did); H5Gclose(imageGroup); H5Fclose(fid);

    if (s < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead, @"tile H5Dread failed");
        return nil;
    }
    return out;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOMSImage class]]) return NO;
    MPGOMSImage *o = (MPGOMSImage *)other;
    return _width == o.width
        && _height == o.height
        && _spectralPoints == o.spectralPoints
        && _tileSize == o.tileSize
        && [_cube isEqualToData:o.cube];
}

- (NSUInteger)hash { return _width ^ _height ^ _spectralPoints ^ [_cube hash]; }

@end
