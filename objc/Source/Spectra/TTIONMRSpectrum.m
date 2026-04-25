#import "TTIONMRSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIONMRSpectrum

- (instancetype)initWithChemicalShiftArray:(TTIOSignalArray *)cs
                            intensityArray:(TTIOSignalArray *)intensity
                               nucleusType:(NSString *)nucleus
                  spectrometerFrequencyMHz:(double)freq
                             indexPosition:(NSUInteger)indexPosition
                           scanTimeSeconds:(double)scanTime
                                     error:(NSError **)error
{
    if (cs.length != intensity.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIONMRSpectrum: chemical_shift length != intensity length");
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

- (TTIOSignalArray *)chemicalShiftArray { return self.signalArrays[@"chemical_shift"]; }
- (TTIOSignalArray *)intensityArray     { return self.signalArrays[@"intensity"]; }

- (BOOL)writeAdditionalAttributesToGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    if (![group setStringAttribute:@"nucleus_type" value:(_nucleusType ?: @"")
                              error:error]) return NO;
    TTIOHDF5Dataset *d = [group createDatasetNamed:@"_spectrometer_freq_mhz"
                                          precision:TTIOPrecisionFloat64
                                             length:1
                                          chunkSize:0
                                   compressionLevel:0
                                              error:error];
    if (!d) return NO;
    double f[1] = { _spectrometerFrequencyMHz };
    return [d writeData:[NSData dataWithBytes:f length:sizeof(f)] error:error];
}

- (BOOL)readAdditionalAttributesFromGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    _nucleusType = [group stringAttributeNamed:@"nucleus_type" error:error];
    TTIOHDF5Dataset *d = [group openDatasetNamed:@"_spectrometer_freq_mhz" error:error];
    NSData *data = [d readDataWithError:error];
    if (!data) return NO;
    _spectrometerFrequencyMHz = ((const double *)data.bytes)[0];
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[TTIONMRSpectrum class]]) return NO;
    TTIONMRSpectrum *o = (TTIONMRSpectrum *)other;
    if (![_nucleusType isEqualToString:o.nucleusType]) return NO;
    if (_spectrometerFrequencyMHz != o.spectrometerFrequencyMHz) return NO;
    return YES;
}

@end
