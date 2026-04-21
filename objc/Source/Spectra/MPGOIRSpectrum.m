#import "MPGOIRSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOIRSpectrum

- (instancetype)initWithWavenumberArray:(MPGOSignalArray *)wavenumbers
                         intensityArray:(MPGOSignalArray *)intensity
                                   mode:(MPGOIRMode)mode
                        resolutionCmInv:(double)resolutionCmInv
                          numberOfScans:(NSUInteger)numberOfScans
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error
{
    if (wavenumbers.length != intensity.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOIRSpectrum: wavenumber length != intensity length");
        return nil;
    }
    NSDictionary *arrays = @{ @"wavenumber": wavenumbers, @"intensity": intensity };
    self = [super initWithSignalArrays:arrays
                                  axes:@[]
                         indexPosition:indexPosition
                       scanTimeSeconds:scanTime
                           precursorMz:0
                       precursorCharge:0];
    if (self) {
        _mode            = mode;
        _resolutionCmInv = resolutionCmInv;
        _numberOfScans   = numberOfScans;
    }
    return self;
}

- (MPGOSignalArray *)wavenumberArray { return self.signalArrays[@"wavenumber"]; }
- (MPGOSignalArray *)intensityArray  { return self.signalArrays[@"intensity"]; }

- (BOOL)writeAdditionalAttributesToGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    NSString *modeStr = (_mode == MPGOIRModeAbsorbance) ? @"absorbance" : @"transmittance";
    if (![group setStringAttribute:@"ir_mode" value:modeStr error:error]) return NO;
    if (![group setIntegerAttribute:@"number_of_scans"
                              value:(int64_t)_numberOfScans
                              error:error]) return NO;
    MPGOHDF5Dataset *d = [group createDatasetNamed:@"_resolution_cm_inv"
                                          precision:MPGOPrecisionFloat64
                                             length:1
                                          chunkSize:0
                                   compressionLevel:0
                                              error:error];
    if (!d) return NO;
    double buf[1] = { _resolutionCmInv };
    return [d writeData:[NSData dataWithBytes:buf length:sizeof(buf)] error:error];
}

- (BOOL)readAdditionalAttributesFromGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    NSString *modeStr = [group stringAttributeNamed:@"ir_mode" error:error];
    _mode = [modeStr isEqualToString:@"absorbance"] ? MPGOIRModeAbsorbance
                                                    : MPGOIRModeTransmittance;
    BOOL exists = NO;
    _numberOfScans = (NSUInteger)[group integerAttributeNamed:@"number_of_scans"
                                                       exists:&exists error:error];
    MPGOHDF5Dataset *d = [group openDatasetNamed:@"_resolution_cm_inv" error:error];
    if (!d) return NO;
    NSData *data = [d readDataWithError:error];
    if (!data) return NO;
    _resolutionCmInv = ((const double *)data.bytes)[0];
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGOIRSpectrum class]]) return NO;
    MPGOIRSpectrum *o = (MPGOIRSpectrum *)other;
    if (_mode            != o.mode)            return NO;
    if (_resolutionCmInv != o.resolutionCmInv) return NO;
    if (_numberOfScans   != o.numberOfScans)   return NO;
    return YES;
}

@end
