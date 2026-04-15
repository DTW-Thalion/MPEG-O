#import "MPGOHDF5Dataset.h"
#import "MPGOHDF5Errors.h"
#import "MPGOHDF5Types.h"
#import <hdf5.h>

@implementation MPGOHDF5Dataset
{
    hid_t          _did;
    MPGOPrecision  _precision;
    NSUInteger     _length;
    id             _retainer;
}

- (instancetype)initWithDatasetId:(hid_t)did
                        precision:(MPGOPrecision)precision
                           length:(NSUInteger)length
                         retainer:(id)retainer
{
    self = [super init];
    if (self) {
        _did = did;
        _precision = precision;
        _length = length;
        _retainer = retainer;
    }
    return self;
}

- (hid_t)datasetId         { return _did; }
- (MPGOPrecision)precision { return _precision; }
- (NSUInteger)length       { return _length; }

- (BOOL)writeData:(NSData *)data error:(NSError **)error
{
    NSUInteger expected = _length * MPGOPrecisionElementSize(_precision);
    if (data.length != expected) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"writeData: expected %lu bytes, got %lu",
            (unsigned long)expected, (unsigned long)data.length);
        return NO;
    }
    hid_t htype = MPGOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dwrite(_did, htype, H5S_ALL, H5S_ALL, H5P_DEFAULT, data.bytes);
    if (!MPGOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    if (s < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
            @"H5Dwrite failed");
        return NO;
    }
    return YES;
}

- (NSData *)readDataWithError:(NSError **)error
{
    NSUInteger bytes = _length * MPGOPrecisionElementSize(_precision);
    NSMutableData *out = [NSMutableData dataWithLength:bytes];
    hid_t htype = MPGOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dread(_did, htype, H5S_ALL, H5S_ALL, H5P_DEFAULT, out.mutableBytes);
    if (!MPGOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    if (s < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
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
        if (error) *error = MPGOMakeError(MPGOErrorOutOfRange,
            @"hyperslab [%lu, %lu) exceeds dataset length %lu",
            (unsigned long)offset, (unsigned long)(offset + count),
            (unsigned long)_length);
        return nil;
    }

    hid_t fspace = H5Dget_space(_did);
    hsize_t off[1]   = { (hsize_t)offset };
    hsize_t cnt[1]   = { (hsize_t)count };
    H5Sselect_hyperslab(fspace, H5S_SELECT_SET, off, NULL, cnt, NULL);

    hid_t mspace = H5Screate_simple(1, cnt, NULL);

    NSUInteger bytes = count * MPGOPrecisionElementSize(_precision);
    NSMutableData *out = [NSMutableData dataWithLength:bytes];
    hid_t htype = MPGOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dread(_did, htype, mspace, fspace, H5P_DEFAULT, out.mutableBytes);
    if (!MPGOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    H5Sclose(mspace); H5Sclose(fspace);

    if (s < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
            @"H5Dread (hyperslab) failed");
        return nil;
    }
    return out;
}

- (void)dealloc
{
    if (_did >= 0) H5Dclose(_did);
}

@end
