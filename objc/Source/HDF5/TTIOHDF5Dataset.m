#import "TTIOHDF5Dataset.h"
#import "TTIOHDF5File.h"
#import "TTIOHDF5Errors.h"
#import "TTIOHDF5Types.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import <hdf5.h>

@implementation TTIOHDF5Dataset
{
    hid_t          _did;
    TTIOPrecision  _precision;
    NSUInteger     _length;
    id             _retainer;
    TTIOHDF5File  *_file;   // cached owning file for wrapper rwlock (M23)
}

- (instancetype)initWithDatasetId:(hid_t)did
                        precision:(TTIOPrecision)precision
                           length:(NSUInteger)length
                         retainer:(id)retainer
{
    self = [super init];
    if (self) {
        _did = did;
        _precision = precision;
        _length = length;
        _retainer = retainer;
        if ([retainer respondsToSelector:@selector(owningFile)]) {
            _file = [(id)retainer owningFile];
        }
    }
    return self;
}

- (hid_t)datasetId         { return _did; }
- (TTIOPrecision)precision { return _precision; }
- (NSUInteger)length       { return _length; }

- (BOOL)writeData:(NSData *)data error:(NSError **)error
{
    NSUInteger expected = _length * TTIOPrecisionElementSize(_precision);
    if (data.length != expected) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"writeData: expected %lu bytes, got %lu",
            (unsigned long)expected, (unsigned long)data.length);
        return NO;
    }
    [_file lockForWriting];
    hid_t htype = TTIOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dwrite(_did, htype, H5S_ALL, H5S_ALL, H5P_DEFAULT, data.bytes);
    if (!TTIOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    [_file unlockForWriting];
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dwrite failed");
        return NO;
    }
    return YES;
}

- (NSData *)readDataWithError:(NSError **)error
{
    NSUInteger bytes = _length * TTIOPrecisionElementSize(_precision);
    NSMutableData *out = [NSMutableData dataWithLength:bytes];
    [_file lockForReading];
    hid_t htype = TTIOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dread(_did, htype, H5S_ALL, H5S_ALL, H5P_DEFAULT, out.mutableBytes);
    if (!TTIOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    [_file unlockForReading];
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"H5Dread failed");
        return nil;
    }
    return out;
}

- (NSData *)readDataAtOffset:(NSUInteger)offset
                       count:(NSUInteger)count
                       error:(NSError **)error
{
    if (offset + count > _length) {
        if (error) *error = TTIOMakeError(TTIOErrorOutOfRange,
            @"hyperslab [%lu, %lu) exceeds dataset length %lu",
            (unsigned long)offset, (unsigned long)(offset + count),
            (unsigned long)_length);
        return nil;
    }

    [_file lockForReading];

    hid_t fspace = H5Dget_space(_did);
    hsize_t off[1]   = { (hsize_t)offset };
    hsize_t cnt[1]   = { (hsize_t)count };
    H5Sselect_hyperslab(fspace, H5S_SELECT_SET, off, NULL, cnt, NULL);

    hid_t mspace = H5Screate_simple(1, cnt, NULL);

    NSUInteger bytes = count * TTIOPrecisionElementSize(_precision);
    NSMutableData *out = [NSMutableData dataWithLength:bytes];
    hid_t htype = TTIOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dread(_did, htype, mspace, fspace, H5P_DEFAULT, out.mutableBytes);
    if (!TTIOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    H5Sclose(mspace); H5Sclose(fspace);

    [_file unlockForReading];

    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"H5Dread (hyperslab) failed");
        return nil;
    }
    return out;
}

- (void)dealloc
{
    if (_did >= 0) H5Dclose(_did);
}

#pragma mark - <TTIOStorageDataset> bridge methods (Option B / M44 catch-up)

// Protocol method names that delegate to the HDF5-typed methods above.
// Upper-layer writers (SignalArray, AcquisitionRun, ...) call only these
// protocol methods so they work against any provider.

- (NSString *)name
{
    [_file lockForReading];
    ssize_t sz = H5Iget_name(_did, NULL, 0);
    if (sz <= 0) { [_file unlockForReading]; return @""; }
    char *buf = malloc((size_t)sz + 1);
    H5Iget_name(_did, buf, (size_t)sz + 1);
    [_file unlockForReading];
    NSString *full = [NSString stringWithUTF8String:buf];
    free(buf);
    NSRange slash = [full rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound || slash.location + 1 >= full.length) {
        return full;
    }
    return [full substringFromIndex:slash.location + 1];
}

- (NSArray<NSNumber *> *)shape
{
    return @[@(_length)];
}

- (NSArray<NSNumber *> *)chunks
{
    // Best-effort introspection; HDF5 layout interrogation is uncommon.
    [_file lockForReading];
    hid_t dcpl = H5Dget_create_plist(_did);
    H5D_layout_t layout = H5Pget_layout(dcpl);
    NSArray<NSNumber *> *out = nil;
    if (layout == H5D_CHUNKED) {
        int rank = H5Pget_chunk(dcpl, 0, NULL);
        if (rank > 0) {
            hsize_t *dims = malloc(sizeof(hsize_t) * (size_t)rank);
            H5Pget_chunk(dcpl, rank, dims);
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)rank];
            for (int i = 0; i < rank; i++) [arr addObject:@((unsigned long long)dims[i])];
            out = arr;
            free(dims);
        }
    }
    H5Pclose(dcpl);
    [_file unlockForReading];
    return out;
}

- (NSArray<TTIOCompoundField *> *)compoundFields
{
    return nil;  // compound datasets are exposed via TTIOHDF5CompoundDatasetAdapter
}

- (id)readAll:(NSError **)error
{
    return [self readDataWithError:error];
}

- (id)readSliceAtOffset:(NSUInteger)offset
                  count:(NSUInteger)count
                  error:(NSError **)error
{
    return [self readDataAtOffset:offset count:count error:error];
}

- (BOOL)writeAll:(id)data error:(NSError **)error
{
    if (![data isKindOfClass:[NSData class]]) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"writeAll: expects NSData for primitive HDF5 dataset, got %@",
            [data class]);
        return NO;
    }
    return [self writeData:(NSData *)data error:error];
}

- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
        @"readRows: not supported on primitive TTIOHDF5Dataset; "
        @"compound reads go through TTIOHDF5CompoundDatasetAdapter");
    return nil;
}

- (NSData *)readCanonicalBytes:(NSError **)error
{
    // Primitive numeric: little-endian packed values. HDF5 native reads
    // produce LE on x86_64; matches Python/Java canonical layout.
    return [self readDataWithError:error];
}

- (BOOL)hasAttributeNamed:(NSString *)name
{
    [_file lockForReading];
    htri_t exists = H5Aexists(_did, [name UTF8String]);
    [_file unlockForReading];
    return exists > 0;
}

- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
        @"attributeValueForName: not yet supported on TTIOHDF5Dataset; "
        @"datasets currently only carry shape/chunks intrinsic metadata");
    return nil;
}

- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    (void)value; (void)name;
    if (error) *error = TTIOMakeError(TTIOErrorAttributeWrite,
        @"setAttributeValue: not yet supported on TTIOHDF5Dataset");
    return NO;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    [_file lockForWriting];
    herr_t s = H5Adelete(_did, [name UTF8String]);
    [_file unlockForWriting];
    if (s < 0 && error) {
        *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"H5Adelete failed for '%@'", name);
    }
    return s >= 0;
}

- (NSArray<NSString *> *)attributeNames
{
    return @[];  // not commonly used for primitive HDF5 datasets
}

@end
