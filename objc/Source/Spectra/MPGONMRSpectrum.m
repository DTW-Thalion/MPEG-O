#import "MPGONMRSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGONMRSpectrum

- (instancetype)initWithChemicalShiftArray:(MPGOSignalArray *)cs
                            intensityArray:(MPGOSignalArray *)intensity
                               nucleusType:(NSString *)nucleus
                  spectrometerFrequencyMHz:(double)freq
                             indexPosition:(NSUInteger)indexPosition
                           scanTimeSeconds:(double)scanTime
                                     error:(NSError **)error
{
    if (cs.length != intensity.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGONMRSpectrum: chemical_shift length != intensity length");
        return nil;
    }
    NSDictionary *arrays = @{ @"chemical_shift": cs, @"intensity": intensity };
    self = [super initWithSignalArrays:arrays
                                  axes:@[]
                         indexPosition:indexPosition
                       scanTimeSeconds:scanTime
                           precursorMz:0
                       precursorCharge:0];
    if (self) {
        _nucleusType              = [nucleus copy];
        _spectrometerFrequencyMHz = freq;
    }
    return self;
}

- (MPGOSignalArray *)chemicalShiftArray { return self.signalArrays[@"chemical_shift"]; }
- (MPGOSignalArray *)intensityArray     { return self.signalArrays[@"intensity"]; }

- (BOOL)writeAdditionalAttributesToGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    if (![group setStringAttribute:@"nucleus_type" value:(_nucleusType ?: @"")
                              error:error]) return NO;
    MPGOHDF5Dataset *d = [group createDatasetNamed:@"_spectrometer_freq_mhz"
                                          precision:MPGOPrecisionFloat64
                                             length:1
                                          chunkSize:0
                                   compressionLevel:0
                                              error:error];
    if (!d) return NO;
    double f[1] = { _spectrometerFrequencyMHz };
    return [d writeData:[NSData dataWithBytes:f length:sizeof(f)] error:error];
}

- (BOOL)readAdditionalAttributesFromGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    _nucleusType = [group stringAttributeNamed:@"nucleus_type" error:error];
    MPGOHDF5Dataset *d = [group openDatasetNamed:@"_spectrometer_freq_mhz" error:error];
    NSData *data = [d readDataWithError:error];
    if (!data) return NO;
    _spectrometerFrequencyMHz = ((const double *)data.bytes)[0];
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGONMRSpectrum class]]) return NO;
    MPGONMRSpectrum *o = (MPGONMRSpectrum *)other;
    if (![_nucleusType isEqualToString:o.nucleusType]) return NO;
    if (_spectrometerFrequencyMHz != o.spectrometerFrequencyMHz) return NO;
    return YES;
}

@end
