#import "TTIOUVVisSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOUVVisSpectrum

- (instancetype)initWithWavelengthArray:(TTIOSignalArray *)wavelengths
                        absorbanceArray:(TTIOSignalArray *)absorbance
                           pathLengthCm:(double)pathLengthCm
                                solvent:(NSString *)solvent
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error
{
    if (wavelengths.length != absorbance.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOUVVisSpectrum: wavelength length != absorbance length");
        return nil;
    }
    NSDictionary *arrays = @{ @"wavelength": wavelengths, @"absorbance": absorbance };
    self = [super initWithSignalArrays:arrays
                                  axes:@[]
                         indexPosition:indexPosition
                       scanTimeSeconds:scanTime
                           precursorMz:0
                       precursorCharge:0];
    if (self) {
        _pathLengthCm = pathLengthCm;
        _solvent      = [solvent copy] ?: @"";
    }
    return self;
}

- (TTIOSignalArray *)wavelengthArray { return self.signalArrays[@"wavelength"]; }
- (TTIOSignalArray *)absorbanceArray { return self.signalArrays[@"absorbance"]; }

static BOOL writeDoubleScalar(TTIOHDF5Group *group, NSString *name,
                              double value, NSError **error)
{
    TTIOHDF5Dataset *d = [group createDatasetNamed:name
                                          precision:TTIOPrecisionFloat64
                                             length:1
                                          chunkSize:0
                                   compressionLevel:0
                                              error:error];
    if (!d) return NO;
    double buf[1] = { value };
    return [d writeData:[NSData dataWithBytes:buf length:sizeof(buf)] error:error];
}

static BOOL readDoubleScalar(TTIOHDF5Group *group, NSString *name,
                             double *out, NSError **error)
{
    TTIOHDF5Dataset *d = [group openDatasetNamed:name error:error];
    if (!d) return NO;
    NSData *data = [d readDataWithError:error];
    if (!data) return NO;
    *out = ((const double *)data.bytes)[0];
    return YES;
}

- (BOOL)writeAdditionalAttributesToGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    if (!writeDoubleScalar(group, @"_path_length_cm", _pathLengthCm, error)) return NO;
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    if (!readDoubleScalar(group, @"_path_length_cm", &_pathLengthCm, error)) return NO;
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[TTIOUVVisSpectrum class]]) return NO;
    TTIOUVVisSpectrum *o = (TTIOUVVisSpectrum *)other;
    if (_pathLengthCm != o.pathLengthCm) return NO;
    if (![_solvent isEqualToString:o.solvent]) return NO;
    return YES;
}

@end
