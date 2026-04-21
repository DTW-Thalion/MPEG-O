#import "MPGOUVVisSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOUVVisSpectrum

- (instancetype)initWithWavelengthArray:(MPGOSignalArray *)wavelengths
                        absorbanceArray:(MPGOSignalArray *)absorbance
                           pathLengthCm:(double)pathLengthCm
                                solvent:(NSString *)solvent
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error
{
    if (wavelengths.length != absorbance.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOUVVisSpectrum: wavelength length != absorbance length");
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

- (MPGOSignalArray *)wavelengthArray { return self.signalArrays[@"wavelength"]; }
- (MPGOSignalArray *)absorbanceArray { return self.signalArrays[@"absorbance"]; }

static BOOL writeDoubleScalar(MPGOHDF5Group *group, NSString *name,
                              double value, NSError **error)
{
    MPGOHDF5Dataset *d = [group createDatasetNamed:name
                                          precision:MPGOPrecisionFloat64
                                             length:1
                                          chunkSize:0
                                   compressionLevel:0
                                              error:error];
    if (!d) return NO;
    double buf[1] = { value };
    return [d writeData:[NSData dataWithBytes:buf length:sizeof(buf)] error:error];
}

static BOOL readDoubleScalar(MPGOHDF5Group *group, NSString *name,
                             double *out, NSError **error)
{
    MPGOHDF5Dataset *d = [group openDatasetNamed:name error:error];
    if (!d) return NO;
    NSData *data = [d readDataWithError:error];
    if (!data) return NO;
    *out = ((const double *)data.bytes)[0];
    return YES;
}

- (BOOL)writeAdditionalAttributesToGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    if (!writeDoubleScalar(group, @"_path_length_cm", _pathLengthCm, error)) return NO;
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    if (!readDoubleScalar(group, @"_path_length_cm", &_pathLengthCm, error)) return NO;
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGOUVVisSpectrum class]]) return NO;
    MPGOUVVisSpectrum *o = (MPGOUVVisSpectrum *)other;
    if (_pathLengthCm != o.pathLengthCm) return NO;
    if (![_solvent isEqualToString:o.solvent]) return NO;
    return YES;
}

@end
