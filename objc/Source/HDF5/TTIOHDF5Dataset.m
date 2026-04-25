#import "TTIOHDF5Dataset.h"
#import "TTIOHDF5File.h"
#import "TTIOHDF5Errors.h"
#import "TTIOHDF5Types.h"
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

@end
