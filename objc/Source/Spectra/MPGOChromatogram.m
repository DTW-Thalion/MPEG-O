#import "MPGOChromatogram.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOChromatogram

- (instancetype)initWithTimeArray:(MPGOSignalArray *)time
                   intensityArray:(MPGOSignalArray *)intensity
                             type:(MPGOChromatogramType)type
                         targetMz:(double)targetMz
                      precursorMz:(double)precursorMz
                        productMz:(double)productMz
                            error:(NSError **)error
{
    if (time.length != intensity.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOChromatogram: time length != intensity length");
        return nil;
    }
    NSDictionary *arrays = @{ @"time": time, @"intensity": intensity };
    self = [super initWithSignalArrays:arrays
                                  axes:@[]
                         indexPosition:0
                       scanTimeSeconds:0
                           precursorMz:precursorMz
                       precursorCharge:0];
    if (self) {
        _type               = type;
        _targetMz           = targetMz;
        _precursorProductMz = precursorMz;
        _productMz          = productMz;
    }
    return self;
}

- (MPGOSignalArray *)timeArray      { return self.signalArrays[@"time"]; }
- (MPGOSignalArray *)intensityArray { return self.signalArrays[@"intensity"]; }

- (BOOL)writeAdditionalAttributesToGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    if (![group setIntegerAttribute:@"chromatogram_type"
                              value:(int64_t)_type error:error]) return NO;
    double tp[3] = { _targetMz, _precursorProductMz, _productMz };
    MPGOHDF5Dataset *d = [group createDatasetNamed:@"_chromatogram_mzs"
                                          precision:MPGOPrecisionFloat64
                                             length:3
                                          chunkSize:0
                                   compressionLevel:0
                                              error:error];
    if (!d) return NO;
    return [d writeData:[NSData dataWithBytes:tp length:sizeof(tp)] error:error];
}

- (BOOL)readAdditionalAttributesFromGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    BOOL exists = NO;
    _type = (MPGOChromatogramType)[group integerAttributeNamed:@"chromatogram_type"
                                                        exists:&exists error:error];
    MPGOHDF5Dataset *d = [group openDatasetNamed:@"_chromatogram_mzs" error:error];
    NSData *data = [d readDataWithError:error];
    if (!data) return NO;
    const double *p = data.bytes;
    _targetMz           = p[0];
    _precursorProductMz = p[1];
    _productMz          = p[2];
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGOChromatogram class]]) return NO;
    MPGOChromatogram *o = (MPGOChromatogram *)other;
    return _type == o.type
        && _targetMz == o.targetMz
        && _precursorProductMz == o.precursorProductMz
        && _productMz == o.productMz;
}

@end
