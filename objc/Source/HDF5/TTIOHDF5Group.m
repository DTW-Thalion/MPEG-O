#import "TTIOHDF5Group.h"
#import "TTIOHDF5Dataset.h"
#import "TTIOHDF5File.h"
#import "TTIOHDF5Errors.h"
#import "TTIOHDF5Types.h"
#import <hdf5.h>

@implementation TTIOHDF5Group
{
    hid_t           _gid;
    id              _retainer;   // strong ref to parent (TTIOHDF5File or TTIOHDF5Group)
    TTIOHDF5File   *_file;       // cached owning file (for the wrapper rwlock)
}

- (instancetype)initWithGroupId:(hid_t)gid retainer:(id)retainer
{
    self = [super init];
    if (self) {
        _gid = gid;
        _retainer = retainer;
        if ([retainer respondsToSelector:@selector(owningFile)]) {
            _file = [(id)retainer owningFile];
        }
    }
    return self;
}

- (hid_t)groupId { return _gid; }

- (TTIOHDF5File *)owningFile { return _file; }

#pragma mark - Sub-groups

- (TTIOHDF5Group *)createGroupNamed:(NSString *)name error:(NSError **)error
{
    [_file lockForWriting];
    hid_t cid = H5Gcreate2(_gid, [name UTF8String], H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    [_file unlockForWriting];
    if (cid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorGroupCreate,
            @"H5Gcreate2 failed for '%@'", name);
        return nil;
    }
    return [[TTIOHDF5Group alloc] initWithGroupId:cid retainer:self];
}

- (TTIOHDF5Group *)openGroupNamed:(NSString *)name error:(NSError **)error
{
    [_file lockForReading];
    hid_t cid = H5Gopen2(_gid, [name UTF8String], H5P_DEFAULT);
    [_file unlockForReading];
    if (cid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorGroupOpen,
            @"H5Gopen2 failed for '%@'", name);
        return nil;
    }
    return [[TTIOHDF5Group alloc] initWithGroupId:cid retainer:self];
}

- (BOOL)hasChildNamed:(NSString *)name
{
    [_file lockForReading];
    htri_t exists = H5Lexists(_gid, [name UTF8String], H5P_DEFAULT);
    [_file unlockForReading];
    return exists > 0;
}

- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error
{
    [_file lockForWriting];
    htri_t exists = H5Lexists(_gid, [name UTF8String], H5P_DEFAULT);
    BOOL ok = YES;
    if (exists > 0) {
        herr_t s = H5Ldelete(_gid, [name UTF8String], H5P_DEFAULT);
        if (s < 0) ok = NO;
    }
    [_file unlockForWriting];
    if (!ok && error) {
        *error = TTIOMakeError(TTIOErrorDatasetCreate,
            @"H5Ldelete failed for '%@'", name);
    }
    return ok;
}

#pragma mark - Datasets

- (TTIOHDF5Dataset *)createDatasetNamed:(NSString *)name
                              precision:(TTIOPrecision)precision
                                 length:(NSUInteger)length
                              chunkSize:(NSUInteger)chunkSize
                       compressionLevel:(int)compressionLevel
                                  error:(NSError **)error
{
    return [self createDatasetNamed:name
                          precision:precision
                             length:length
                          chunkSize:chunkSize
                        compression:TTIOCompressionZlib
                   compressionLevel:compressionLevel
                              error:error];
}

#define TTIO_HDF5_LZ4_FILTER_ID 32004u

- (TTIOHDF5Dataset *)createDatasetNamed:(NSString *)name
                              precision:(TTIOPrecision)precision
                                 length:(NSUInteger)length
                              chunkSize:(NSUInteger)chunkSize
                            compression:(TTIOCompression)compression
                       compressionLevel:(int)compressionLevel
                                  error:(NSError **)error
{
    // Single-exit refactor: all early-return paths set (did, errCode, errMsg)
    // and goto cleanup, which releases the write lock and constructs the result.
    hid_t space = -1, plist = -1, htype = -1, did = -1;
    TTIOErrorCode errCode = TTIOErrorDatasetCreate;
    NSString *errMsg = nil;

    [_file lockForWriting];

    hsize_t dims[1] = { (hsize_t)length };
    space = H5Screate_simple(1, dims, NULL);
    if (space < 0) {
        errMsg = [NSString stringWithFormat:@"H5Screate_simple failed for '%@'", name];
        goto cleanup;
    }

    plist = H5Pcreate(H5P_DATASET_CREATE);
    if (plist < 0) {
        errMsg = [NSString stringWithFormat:@"H5Pcreate failed for '%@'", name];
        goto cleanup;
    }

    if (chunkSize > 0 && length > 0) {
        hsize_t chunk[1] = { (hsize_t)MIN(chunkSize, length) };
        H5Pset_chunk(plist, 1, chunk);
        if (compression == TTIOCompressionZlib && compressionLevel > 0) {
            H5Pset_deflate(plist, (unsigned)compressionLevel);
        } else if (compression == TTIOCompressionLZ4) {
            if (H5Zfilter_avail((H5Z_filter_t)TTIO_HDF5_LZ4_FILTER_ID) <= 0) {
                errMsg = @"LZ4 filter (id 32004) is not available; install "
                         @"the hdf5plugin package or set HDF5_PLUGIN_PATH";
                goto cleanup;
            }
            if (H5Pset_filter(plist, TTIO_HDF5_LZ4_FILTER_ID,
                              H5Z_FLAG_MANDATORY, 0, NULL) < 0) {
                errMsg = [NSString stringWithFormat:
                    @"H5Pset_filter(LZ4) failed for '%@'", name];
                goto cleanup;
            }
        }
    }

    htype = TTIOHDF5TypeForPrecision(precision);
    if (htype < 0) {
        errCode = TTIOErrorInvalidArgument;
        errMsg = [NSString stringWithFormat:@"unknown precision for '%@'", name];
        goto cleanup;
    }

    did = H5Dcreate2(_gid, [name UTF8String], htype, space,
                     H5P_DEFAULT, plist, H5P_DEFAULT);
    if (did < 0) {
        errMsg = [NSString stringWithFormat:@"H5Dcreate2 failed for '%@'", name];
        goto cleanup;
    }

cleanup:
    if (htype >= 0 && !TTIOHDF5TypeIsBuiltin(precision)) H5Tclose(htype);
    if (plist >= 0) H5Pclose(plist);
    if (space >= 0) H5Sclose(space);

    [_file unlockForWriting];

    if (did < 0) {
        if (error) *error = TTIOMakeError(errCode, @"%@", errMsg);
        return nil;
    }
    return [[TTIOHDF5Dataset alloc] initWithDatasetId:did
                                            precision:precision
                                               length:length
                                             retainer:self];
}

- (TTIOHDF5Dataset *)openDatasetNamed:(NSString *)name error:(NSError **)error
{
    [_file lockForReading];
    hid_t did = H5Dopen2(_gid, [name UTF8String], H5P_DEFAULT);
    if (did < 0) {
        [_file unlockForReading];
        if (error) *error = TTIOMakeError(TTIOErrorDatasetOpen,
            @"H5Dopen2 failed for '%@'", name);
        return nil;
    }

    hid_t space = H5Dget_space(did);
    hsize_t dims[1] = { 0 };
    H5Sget_simple_extent_dims(space, dims, NULL);
    H5Sclose(space);

    hid_t htype = H5Dget_type(did);
    TTIOPrecision precision = TTIOPrecisionFloat64;
    if (H5Tequal(htype, H5T_NATIVE_FLOAT)  > 0) precision = TTIOPrecisionFloat32;
    else if (H5Tequal(htype, H5T_NATIVE_DOUBLE) > 0) precision = TTIOPrecisionFloat64;
    else if (H5Tequal(htype, H5T_NATIVE_INT32)  > 0) precision = TTIOPrecisionInt32;
    else if (H5Tequal(htype, H5T_NATIVE_INT64)  > 0) precision = TTIOPrecisionInt64;
    // M82: UINT64 datasets (genomic_index/offsets) round-trip as UINT64.
    // Pre-M82 spectrum_index/offsets were written by Python as native
    // uint64 but lacked an ObjC TTIOPrecisionUInt64 enum value, so they
    // were read back as INT64 (bit-identical for non-negative offsets).
    // M82 added the UINT64 enum value so genomic data round-trips with
    // its declared precision. The pre-M82 spectrum_index files still
    // read back correctly because the on-disk bytes are identical and
    // SpectrumIndex's internal ivars treat them as uint64 either way.
    else if (H5Tequal(htype, H5T_NATIVE_UINT64) > 0) precision = TTIOPrecisionUInt64;
    else if (H5Tequal(htype, H5T_NATIVE_UINT32) > 0) precision = TTIOPrecisionUInt32;
    else if (H5Tequal(htype, H5T_NATIVE_UINT8)  > 0) precision = TTIOPrecisionUInt8;
    else if (H5Tget_class(htype) == H5T_COMPOUND && H5Tget_size(htype) == 2 * sizeof(double)) {
        precision = TTIOPrecisionComplex128;
    }
    H5Tclose(htype);
    [_file unlockForReading];

    return [[TTIOHDF5Dataset alloc] initWithDatasetId:did
                                            precision:precision
                                               length:(NSUInteger)dims[0]
                                             retainer:self];
}

#pragma mark - Attributes

- (BOOL)setStringAttribute:(NSString *)name value:(NSString *)value error:(NSError **)error
{
    const char *cstr = [value UTF8String];
    size_t      len  = strlen(cstr);

    [_file lockForWriting];

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
        [_file unlockForWriting];
        if (error) *error = TTIOMakeError(TTIOErrorAttributeCreate,
            @"H5Acreate2 failed for '%@'", name);
        return NO;
    }

    herr_t s = H5Awrite(aid, htype, cstr);
    H5Aclose(aid); H5Sclose(space); H5Tclose(htype);
    [_file unlockForWriting];

    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"H5Awrite failed for '%@'", name);
        return NO;
    }
    return YES;
}

- (NSString *)stringAttributeNamed:(NSString *)name error:(NSError **)error
{
    [_file lockForReading];
    if (H5Aexists(_gid, [name UTF8String]) <= 0) {
        [_file unlockForReading];
        if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"attribute '%@' does not exist", name);
        return nil;
    }
    hid_t aid = H5Aopen(_gid, [name UTF8String], H5P_DEFAULT);
    if (aid < 0) {
        [_file unlockForReading];
        if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"H5Aopen failed for '%@'", name);
        return nil;
    }
    hid_t htype = H5Aget_type(aid);
    NSString *result = nil;
    /* M91 follow-up to M90.7: Python (always) and Java (post-M90.7)
     * write string attributes as VL_STRING with UTF-8 cset. Detect via
     * H5Tis_variable_str and dispatch — old fixed-length attrs still
     * decode through the legacy calloc path. */
    if (H5Tis_variable_str(htype) > 0) {
        char *vlbuf = NULL;
        if (H5Aread(aid, htype, &vlbuf) >= 0 && vlbuf) {
            result = [[NSString alloc] initWithUTF8String:vlbuf];
            /* HDF5 1.10 reclaim API: H5Dvlen_reclaim (renamed to
             * H5Treclaim in 1.12+; we target 1.10 as the lowest
             * common system version on Linux distros). */
            hid_t space = H5Aget_space(aid);
            if (space >= 0) {
                H5Dvlen_reclaim(htype, space, H5P_DEFAULT, &vlbuf);
                H5Sclose(space);
            }
        }
    } else {
        size_t size = H5Tget_size(htype);
        char *buf = (char *)calloc(size + 1, 1);
        H5Aread(aid, htype, buf);
        result = [[NSString alloc] initWithUTF8String:buf];
        free(buf);
    }
    H5Tclose(htype); H5Aclose(aid);
    [_file unlockForReading];
    return result;
}

- (BOOL)setIntegerAttribute:(NSString *)name value:(int64_t)value error:(NSError **)error
{
    [_file lockForWriting];
    hid_t space = H5Screate(H5S_SCALAR);
    if (H5Aexists(_gid, [name UTF8String]) > 0) {
        H5Adelete(_gid, [name UTF8String]);
    }
    hid_t aid = H5Acreate2(_gid, [name UTF8String], H5T_NATIVE_INT64, space,
                           H5P_DEFAULT, H5P_DEFAULT);
    if (aid < 0) {
        H5Sclose(space);
        [_file unlockForWriting];
        if (error) *error = TTIOMakeError(TTIOErrorAttributeCreate,
            @"H5Acreate2 (int) failed for '%@'", name);
        return NO;
    }
    herr_t s = H5Awrite(aid, H5T_NATIVE_INT64, &value);
    H5Aclose(aid); H5Sclose(space);
    [_file unlockForWriting];
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"H5Awrite (int) failed for '%@'", name);
        return NO;
    }
    return YES;
}

- (int64_t)integerAttributeNamed:(NSString *)name exists:(BOOL *)outExists error:(NSError **)error
{
    [_file lockForReading];
    if (H5Aexists(_gid, [name UTF8String]) <= 0) {
        [_file unlockForReading];
        if (outExists) *outExists = NO;
        return 0;
    }
    if (outExists) *outExists = YES;
    hid_t aid = H5Aopen(_gid, [name UTF8String], H5P_DEFAULT);
    if (aid < 0) {
        [_file unlockForReading];
        if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"H5Aopen failed for '%@'", name);
        return 0;
    }
    int64_t value = 0;
    H5Aread(aid, H5T_NATIVE_INT64, &value);
    H5Aclose(aid);
    [_file unlockForReading];
    return value;
}

- (BOOL)hasAttributeNamed:(NSString *)name
{
    [_file lockForReading];
    htri_t exists = H5Aexists(_gid, [name UTF8String]);
    [_file unlockForReading];
    return exists > 0;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    [_file lockForWriting];
    if (H5Aexists(_gid, [name UTF8String]) > 0) {
        H5Adelete(_gid, [name UTF8String]);
    }
    [_file unlockForWriting];
    return YES;
}

static herr_t collect_attr(hid_t loc, const char *name,
                            const H5A_info_t *ainfo, void *op_data)
{
    (void)loc; (void)ainfo;
    NSMutableArray *out = (__bridge NSMutableArray *)op_data;
    [out addObject:[NSString stringWithUTF8String:name]];
    return 0;
}

- (NSArray<NSString *> *)attributeNames
{
    NSMutableArray *out = [NSMutableArray array];
    [_file lockForReading];
    H5Aiterate2(_gid, H5_INDEX_NAME, H5_ITER_INC, NULL,
                 collect_attr, (__bridge void *)out);
    [_file unlockForReading];
    return out;
}

static herr_t collect_link(hid_t loc, const char *name,
                            const H5L_info_t *linfo, void *op_data)
{
    (void)loc; (void)linfo;
    NSMutableArray *out = (__bridge NSMutableArray *)op_data;
    [out addObject:[NSString stringWithUTF8String:name]];
    return 0;
}

- (NSArray<NSString *> *)childNames
{
    NSMutableArray *out = [NSMutableArray array];
    [_file lockForReading];
    H5Literate(_gid, H5_INDEX_NAME, H5_ITER_INC, NULL,
                collect_link, (__bridge void *)out);
    [_file unlockForReading];
    return out;
}

- (NSString *)groupName
{
    [_file lockForReading];
    ssize_t sz = H5Iget_name(_gid, NULL, 0);
    if (sz <= 0) { [_file unlockForReading]; return @"/"; }
    char *buf = malloc((size_t)sz + 1);
    H5Iget_name(_gid, buf, (size_t)sz + 1);
    [_file unlockForReading];
    NSString *full = [NSString stringWithUTF8String:buf];
    free(buf);
    if (full.length == 0 || [full isEqualToString:@"/"]) return @"/";
    NSRange slash = [full rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound || slash.location + 1 >= full.length) {
        return full;
    }
    return [full substringFromIndex:slash.location + 1];
}

- (void)dealloc
{
    if (_gid >= 0) H5Gclose(_gid);
}

@end
