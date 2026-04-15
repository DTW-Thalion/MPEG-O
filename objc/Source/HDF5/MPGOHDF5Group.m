#import "MPGOHDF5Group.h"
#import "MPGOHDF5Dataset.h"
#import "MPGOHDF5Errors.h"
#import "MPGOHDF5Types.h"
#import <hdf5.h>

@implementation MPGOHDF5Group
{
    hid_t _gid;
    id    _retainer;   // strong ref to the parent (MPGOHDF5File or MPGOHDF5Group)
}

- (instancetype)initWithGroupId:(hid_t)gid retainer:(id)retainer
{
    self = [super init];
    if (self) {
        _gid = gid;
        _retainer = retainer;
    }
    return self;
}

- (hid_t)groupId { return _gid; }

#pragma mark - Sub-groups

- (MPGOHDF5Group *)createGroupNamed:(NSString *)name error:(NSError **)error
{
    hid_t cid = H5Gcreate2(_gid, [name UTF8String], H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (cid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupCreate,
            @"H5Gcreate2 failed for '%@'", name);
        return nil;
    }
    return [[MPGOHDF5Group alloc] initWithGroupId:cid retainer:self];
}

- (MPGOHDF5Group *)openGroupNamed:(NSString *)name error:(NSError **)error
{
    hid_t cid = H5Gopen2(_gid, [name UTF8String], H5P_DEFAULT);
    if (cid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupOpen,
            @"H5Gopen2 failed for '%@'", name);
        return nil;
    }
    return [[MPGOHDF5Group alloc] initWithGroupId:cid retainer:self];
}

- (BOOL)hasChildNamed:(NSString *)name
{
    htri_t exists = H5Lexists(_gid, [name UTF8String], H5P_DEFAULT);
    return exists > 0;
}

#pragma mark - Datasets

- (MPGOHDF5Dataset *)createDatasetNamed:(NSString *)name
                              precision:(MPGOPrecision)precision
                                 length:(NSUInteger)length
                              chunkSize:(NSUInteger)chunkSize
                       compressionLevel:(int)compressionLevel
                                  error:(NSError **)error
{
    hsize_t dims[1] = { (hsize_t)length };
    hid_t   space   = H5Screate_simple(1, dims, NULL);
    if (space < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"H5Screate_simple failed for '%@'", name);
        return nil;
    }

    hid_t plist = H5Pcreate(H5P_DATASET_CREATE);
    if (plist < 0) {
        H5Sclose(space);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"H5Pcreate failed for '%@'", name);
        return nil;
    }

    if (chunkSize > 0 && length > 0) {
        hsize_t chunk[1] = { (hsize_t)MIN(chunkSize, length) };
        H5Pset_chunk(plist, 1, chunk);
        if (compressionLevel > 0) {
            H5Pset_deflate(plist, (unsigned)compressionLevel);
        }
    }

    hid_t htype = MPGOHDF5TypeForPrecision(precision);
    if (htype < 0) {
        H5Pclose(plist); H5Sclose(space);
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"unknown precision for '%@'", name);
        return nil;
    }

    hid_t did = H5Dcreate2(_gid, [name UTF8String], htype, space,
                           H5P_DEFAULT, plist, H5P_DEFAULT);
    if (!MPGOHDF5TypeIsBuiltin(precision)) {
        H5Tclose(htype);
    }
    H5Pclose(plist);
    H5Sclose(space);

    if (did < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"H5Dcreate2 failed for '%@'", name);
        return nil;
    }

    return [[MPGOHDF5Dataset alloc] initWithDatasetId:did
                                            precision:precision
                                               length:length
                                             retainer:self];
}

- (MPGOHDF5Dataset *)openDatasetNamed:(NSString *)name error:(NSError **)error
{
    hid_t did = H5Dopen2(_gid, [name UTF8String], H5P_DEFAULT);
    if (did < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetOpen,
            @"H5Dopen2 failed for '%@'", name);
        return nil;
    }

    hid_t space = H5Dget_space(did);
    hsize_t dims[1] = { 0 };
    H5Sget_simple_extent_dims(space, dims, NULL);
    H5Sclose(space);

    hid_t htype = H5Dget_type(did);
    MPGOPrecision precision = MPGOPrecisionFloat64;
    if (H5Tequal(htype, H5T_NATIVE_FLOAT)  > 0) precision = MPGOPrecisionFloat32;
    else if (H5Tequal(htype, H5T_NATIVE_DOUBLE) > 0) precision = MPGOPrecisionFloat64;
    else if (H5Tequal(htype, H5T_NATIVE_INT32)  > 0) precision = MPGOPrecisionInt32;
    else if (H5Tequal(htype, H5T_NATIVE_INT64)  > 0) precision = MPGOPrecisionInt64;
    else if (H5Tequal(htype, H5T_NATIVE_UINT32) > 0) precision = MPGOPrecisionUInt32;
    else if (H5Tget_class(htype) == H5T_COMPOUND && H5Tget_size(htype) == 2 * sizeof(double)) {
        precision = MPGOPrecisionComplex128;
    }
    H5Tclose(htype);

    return [[MPGOHDF5Dataset alloc] initWithDatasetId:did
                                            precision:precision
                                               length:(NSUInteger)dims[0]
                                             retainer:self];
}

#pragma mark - Attributes

- (BOOL)setStringAttribute:(NSString *)name value:(NSString *)value error:(NSError **)error
{
    const char *cstr = [value UTF8String];
    size_t      len  = strlen(cstr);

    hid_t htype = H5Tcopy(H5T_C_S1);
    H5Tset_size(htype, len > 0 ? len : 1);
    H5Tset_strpad(htype, H5T_STR_NULLTERM);

    hid_t space = H5Screate(H5S_SCALAR);

    if (H5Aexists(_gid, [name UTF8String]) > 0) {
        H5Adelete(_gid, [name UTF8String]);
    }

    hid_t aid = H5Acreate2(_gid, [name UTF8String], htype, space,
                           H5P_DEFAULT, H5P_DEFAULT);
    if (aid < 0) {
        H5Sclose(space); H5Tclose(htype);
        if (error) *error = MPGOMakeError(MPGOErrorAttributeCreate,
            @"H5Acreate2 failed for '%@'", name);
        return NO;
    }

    herr_t s = H5Awrite(aid, htype, cstr);
    H5Aclose(aid); H5Sclose(space); H5Tclose(htype);

    if (s < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"H5Awrite failed for '%@'", name);
        return NO;
    }
    return YES;
}

- (NSString *)stringAttributeNamed:(NSString *)name error:(NSError **)error
{
    if (H5Aexists(_gid, [name UTF8String]) <= 0) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"attribute '%@' does not exist", name);
        return nil;
    }
    hid_t aid = H5Aopen(_gid, [name UTF8String], H5P_DEFAULT);
    if (aid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"H5Aopen failed for '%@'", name);
        return nil;
    }
    hid_t  htype = H5Aget_type(aid);
    size_t size  = H5Tget_size(htype);
    char  *buf   = (char *)calloc(size + 1, 1);
    H5Aread(aid, htype, buf);
    NSString *result = [[NSString alloc] initWithUTF8String:buf];
    free(buf);
    H5Tclose(htype); H5Aclose(aid);
    return result;
}

- (BOOL)setIntegerAttribute:(NSString *)name value:(int64_t)value error:(NSError **)error
{
    hid_t space = H5Screate(H5S_SCALAR);
    if (H5Aexists(_gid, [name UTF8String]) > 0) {
        H5Adelete(_gid, [name UTF8String]);
    }
    hid_t aid = H5Acreate2(_gid, [name UTF8String], H5T_NATIVE_INT64, space,
                           H5P_DEFAULT, H5P_DEFAULT);
    if (aid < 0) {
        H5Sclose(space);
        if (error) *error = MPGOMakeError(MPGOErrorAttributeCreate,
            @"H5Acreate2 (int) failed for '%@'", name);
        return NO;
    }
    herr_t s = H5Awrite(aid, H5T_NATIVE_INT64, &value);
    H5Aclose(aid); H5Sclose(space);
    if (s < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"H5Awrite (int) failed for '%@'", name);
        return NO;
    }
    return YES;
}

- (int64_t)integerAttributeNamed:(NSString *)name exists:(BOOL *)outExists error:(NSError **)error
{
    if (H5Aexists(_gid, [name UTF8String]) <= 0) {
        if (outExists) *outExists = NO;
        return 0;
    }
    if (outExists) *outExists = YES;
    hid_t aid = H5Aopen(_gid, [name UTF8String], H5P_DEFAULT);
    if (aid < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"H5Aopen failed for '%@'", name);
        return 0;
    }
    int64_t value = 0;
    H5Aread(aid, H5T_NATIVE_INT64, &value);
    H5Aclose(aid);
    return value;
}

- (BOOL)hasAttributeNamed:(NSString *)name
{
    return H5Aexists(_gid, [name UTF8String]) > 0;
}

- (void)dealloc
{
    if (_gid >= 0) H5Gclose(_gid);
}

@end
