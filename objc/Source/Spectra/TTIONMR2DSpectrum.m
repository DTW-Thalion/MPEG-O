#import "TTIONMR2DSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOValueRange.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <hdf5.h>
#import <hdf5_hl.h>

@interface TTIONMR2DSpectrum (M12Private)
- (void)writeScaleNamed:(NSString *)name
                 length:(NSUInteger)len
                  range:(TTIOValueRange *)range
               toParent:(hid_t)parentGid
             attachedTo:(hid_t)dataset
               atDimIdx:(unsigned)dim;
@end

@implementation TTIONMR2DSpectrum

- (instancetype)initWithIntensityMatrix:(NSData *)matrix
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                 f1Axis:(TTIOAxisDescriptor *)f1
                                 f2Axis:(TTIOAxisDescriptor *)f2
                              nucleusF1:(NSString *)nucleusF1
                              nucleusF2:(NSString *)nucleusF2
                          indexPosition:(NSUInteger)indexPosition
                                  error:(NSError **)error
{
    NSUInteger expected = width * height * sizeof(double);
    if (matrix.length != expected) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIONMR2DSpectrum: matrix bytes %lu != width*height*8 = %lu",
            (unsigned long)matrix.length, (unsigned long)expected);
        return nil;
    }

    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    TTIOSignalArray *flat = [[TTIOSignalArray alloc] initWithBuffer:matrix
                                                             length:width * height
                                                           encoding:enc
                                                               axis:nil];
    NSDictionary *arrays = @{ @"intensity_matrix": flat };
    self = [super initWithSignalArrays:arrays
                                  axes:@[ f1, f2 ]
                         indexPosition:indexPosition
                       scanTimeSeconds:0
                           precursorMz:0
                       precursorCharge:0];
    if (self) {
        _intensityMatrix = [matrix copy];
        _width           = width;
        _height          = height;
        _f1Axis          = f1;
        _f2Axis          = f2;
        _nucleusF1       = [nucleusF1 copy];
        _nucleusF2       = [nucleusF2 copy];
    }
    return self;
}

- (BOOL)writeAdditionalAttributesToGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    if (![group setIntegerAttribute:@"matrix_width"  value:(int64_t)_width  error:error]) return NO;
    if (![group setIntegerAttribute:@"matrix_height" value:(int64_t)_height error:error]) return NO;
    if (![group setStringAttribute:@"nucleus_f1" value:(_nucleusF1 ?: @"") error:error]) return NO;
    if (![group setStringAttribute:@"nucleus_f2" value:(_nucleusF2 ?: @"") error:error]) return NO;

    // Native 2-D representation (opt_native_2d_nmr). Written alongside
    // the flattened 1-D TTIOSignalArray that the base class persisted;
    // readers prefer this when present.
    hid_t parentGid = group.groupId;
    hsize_t dims[2] = { (hsize_t)_height, (hsize_t)_width };
    hid_t space = H5Screate_simple(2, dims, NULL);
    hid_t plist = H5Pcreate(H5P_DATASET_CREATE);
    hsize_t chunk[2] = {
        (hsize_t)MIN((NSUInteger)128, _height),
        (hsize_t)MIN((NSUInteger)128, _width)
    };
    if (chunk[0] > 0 && chunk[1] > 0) {
        H5Pset_chunk(plist, 2, chunk);
        H5Pset_deflate(plist, 6);
    }

    hid_t did = H5Dcreate2(parentGid, "intensity_matrix_2d",
                            H5T_NATIVE_DOUBLE, space,
                            H5P_DEFAULT, plist, H5P_DEFAULT);
    if (did < 0) {
        H5Pclose(plist); H5Sclose(space);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetCreate,
            @"H5Dcreate2 intensity_matrix_2d failed");
        return NO;
    }
    herr_t rc = H5Dwrite(did, H5T_NATIVE_DOUBLE,
                          H5S_ALL, H5S_ALL, H5P_DEFAULT, _intensityMatrix.bytes);
    if (rc < 0) {
        H5Dclose(did); H5Pclose(plist); H5Sclose(space);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dwrite intensity_matrix_2d failed");
        return NO;
    }

    // Dimension scales for axis 0 (F1, height) and axis 1 (F2, width).
    [self writeScaleNamed:@"f1_scale"
                   length:_height
                    range:_f1Axis.valueRange
                 toParent:parentGid
                attachedTo:did
                  atDimIdx:0];
    [self writeScaleNamed:@"f2_scale"
                   length:_width
                    range:_f2Axis.valueRange
                 toParent:parentGid
                attachedTo:did
                  atDimIdx:1];

    H5Dclose(did); H5Pclose(plist); H5Sclose(space);
    return YES;
}

- (void)writeScaleNamed:(NSString *)name
                 length:(NSUInteger)len
                  range:(TTIOValueRange *)range
               toParent:(hid_t)parentGid
             attachedTo:(hid_t)dataset
               atDimIdx:(unsigned)dim
{
    if (len == 0) return;
    double *vals = malloc(len * sizeof(double));
    double lo = range ? range.minimum : 0.0;
    double hi = range ? range.maximum : (double)(len - 1);
    double step = (len > 1) ? (hi - lo) / (double)(len - 1) : 0.0;
    for (NSUInteger i = 0; i < len; i++) vals[i] = lo + step * (double)i;

    hsize_t dims[1] = { (hsize_t)len };
    hid_t scaleSpace = H5Screate_simple(1, dims, NULL);
    hid_t scaleDs = H5Dcreate2(parentGid, [name UTF8String],
                                H5T_NATIVE_DOUBLE, scaleSpace,
                                H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (scaleDs >= 0) {
        H5Dwrite(scaleDs, H5T_NATIVE_DOUBLE,
                 H5S_ALL, H5S_ALL, H5P_DEFAULT, vals);
        H5DSset_scale(scaleDs, [name UTF8String]);
        H5DSattach_scale(dataset, scaleDs, dim);
        H5Dclose(scaleDs);
    }
    H5Sclose(scaleSpace);
    free(vals);
}

- (BOOL)readAdditionalAttributesFromGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    BOOL exists = NO;
    _width  = (NSUInteger)[group integerAttributeNamed:@"matrix_width"
                                                exists:&exists error:error];
    _height = (NSUInteger)[group integerAttributeNamed:@"matrix_height"
                                                exists:&exists error:error];
    _nucleusF1 = [group stringAttributeNamed:@"nucleus_f1" error:error];
    _nucleusF2 = [group stringAttributeNamed:@"nucleus_f2" error:error];

    // Prefer the native 2-D dataset if present; fall back to the
    // flattened 1-D signal array (v0.1 / fallback path).
    if ([group hasChildNamed:@"intensity_matrix_2d"]) {
        hid_t did = H5Dopen2(group.groupId, "intensity_matrix_2d", H5P_DEFAULT);
        if (did >= 0) {
            NSUInteger total = _width * _height;
            NSMutableData *m = [NSMutableData dataWithLength:total * sizeof(double)];
            H5Dread(did, H5T_NATIVE_DOUBLE,
                    H5S_ALL, H5S_ALL, H5P_DEFAULT, m.mutableBytes);
            H5Dclose(did);
            _intensityMatrix = [m copy];
            return YES;
        }
    }

    TTIOSignalArray *flat = self.signalArrays[@"intensity_matrix"];
    _intensityMatrix = [flat.buffer copy];
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[TTIONMR2DSpectrum class]]) return NO;
    TTIONMR2DSpectrum *o = (TTIONMR2DSpectrum *)other;
    if (_width != o.width || _height != o.height) return NO;
    if (![_intensityMatrix isEqualToData:o.intensityMatrix]) return NO;
    if (![_nucleusF1 isEqualToString:o.nucleusF1]) return NO;
    if (![_nucleusF2 isEqualToString:o.nucleusF2]) return NO;
    return YES;
}

@end
