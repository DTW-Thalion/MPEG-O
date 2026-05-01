#import "TTIOChromatogram.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOChromatogram

- (instancetype)initWithTimeArray:(TTIOSignalArray *)time
                   intensityArray:(TTIOSignalArray *)intensity
                             type:(TTIOChromatogramType)type
                         targetMz:(double)targetMz
                      precursorMz:(double)precursorMz
                        productMz:(double)productMz
                            error:(NSError **)error
{
    if (time.length != intensity.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOChromatogram: time length != intensity length");
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

- (TTIOSignalArray *)timeArray      { return self.signalArrays[@"time"]; }
- (TTIOSignalArray *)intensityArray { return self.signalArrays[@"intensity"]; }

- (BOOL)writeAdditionalAttributesToGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    if (![group setAttributeValue:@((int64_t)_type)
                          forName:@"chromatogram_type" error:error]) return NO;
    double tp[3] = { _targetMz, _precursorProductMz, _productMz };
    id<TTIOStorageDataset> d = [group createDatasetNamed:@"_chromatogram_mzs"
                                               precision:TTIOPrecisionFloat64
                                                  length:3
                                               chunkSize:0
                                             compression:TTIOCompressionZlib
                                        compressionLevel:0
                                                   error:error];
    if (!d) return NO;
    return [d writeAll:[NSData dataWithBytes:tp length:sizeof(tp)] error:error];
}

- (BOOL)readAdditionalAttributesFromGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    NSNumber *t = [group attributeValueForName:@"chromatogram_type" error:error];
    if (t) _type = (TTIOChromatogramType)[t longLongValue];
    id<TTIOStorageDataset> d = [group openDatasetNamed:@"_chromatogram_mzs" error:error];
    NSData *data = [d readAll:error];
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
    if (![other isKindOfClass:[TTIOChromatogram class]]) return NO;
    TTIOChromatogram *o = (TTIOChromatogram *)other;
    return _type == o.type
        && _targetMz == o.targetMz
        && _precursorProductMz == o.precursorProductMz
        && _productMz == o.productMz;
}

@end
