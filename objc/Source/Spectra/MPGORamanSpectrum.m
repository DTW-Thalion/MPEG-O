#import "MPGORamanSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGORamanSpectrum

- (instancetype)initWithWavenumberArray:(MPGOSignalArray *)wavenumbers
                         intensityArray:(MPGOSignalArray *)intensity
                 excitationWavelengthNm:(double)excitationNm
                           laserPowerMw:(double)laserPowerMw
                     integrationTimeSec:(double)integrationTime
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error
{
    if (wavenumbers.length != intensity.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGORamanSpectrum: wavenumber length != intensity length");
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
        _excitationWavelengthNm = excitationNm;
        _laserPowerMw           = laserPowerMw;
        _integrationTimeSec     = integrationTime;
    }
    return self;
}

- (MPGOSignalArray *)wavenumberArray { return self.signalArrays[@"wavenumber"]; }
- (MPGOSignalArray *)intensityArray  { return self.signalArrays[@"intensity"]; }

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
    if (!writeDoubleScalar(group, @"_excitation_wavelength_nm",
                           _excitationWavelengthNm, error)) return NO;
    if (!writeDoubleScalar(group, @"_laser_power_mw",
                           _laserPowerMw, error)) return NO;
    if (!writeDoubleScalar(group, @"_integration_time_sec",
                           _integrationTimeSec, error)) return NO;
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    if (!readDoubleScalar(group, @"_excitation_wavelength_nm",
                          &_excitationWavelengthNm, error)) return NO;
    if (!readDoubleScalar(group, @"_laser_power_mw",
                          &_laserPowerMw, error)) return NO;
    if (!readDoubleScalar(group, @"_integration_time_sec",
                          &_integrationTimeSec, error)) return NO;
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGORamanSpectrum class]]) return NO;
    MPGORamanSpectrum *o = (MPGORamanSpectrum *)other;
    if (_excitationWavelengthNm != o.excitationWavelengthNm) return NO;
    if (_laserPowerMw           != o.laserPowerMw)           return NO;
    if (_integrationTimeSec     != o.integrationTimeSec)     return NO;
    return YES;
}

@end
