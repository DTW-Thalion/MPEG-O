#import "MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOMassSpectrum

- (instancetype)initWithMzArray:(MPGOSignalArray *)mz
                 intensityArray:(MPGOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(MPGOPolarity)polarity
                     scanWindow:(MPGOValueRange *)scanWindow
               activationMethod:(MPGOActivationMethod)activationMethod
                isolationWindow:(MPGOIsolationWindow *)isolationWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error
{
    if (mz.length != intensity.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOMassSpectrum: mz length (%lu) != intensity length (%lu)",
            (unsigned long)mz.length, (unsigned long)intensity.length);
        return nil;
    }
    NSDictionary *arrays = @{ @"mz": mz, @"intensity": intensity };
    self = [super initWithSignalArrays:arrays
                                  axes:@[]
                         indexPosition:indexPosition
                       scanTimeSeconds:scanTime
                           precursorMz:precursorMz
                       precursorCharge:precursorCharge];
    if (self) {
        _msLevel          = msLevel;
        _polarity         = polarity;
        _scanWindow       = scanWindow;
        _activationMethod = activationMethod;
        _isolationWindow  = isolationWindow;
    }
    return self;
}

- (instancetype)initWithMzArray:(MPGOSignalArray *)mz
                 intensityArray:(MPGOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(MPGOPolarity)polarity
                     scanWindow:(MPGOValueRange *)scanWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error
{
    return [self initWithMzArray:mz
                  intensityArray:intensity
                         msLevel:msLevel
                        polarity:polarity
                      scanWindow:scanWindow
                activationMethod:MPGOActivationMethodNone
                 isolationWindow:nil
                   indexPosition:indexPosition
                 scanTimeSeconds:scanTime
                     precursorMz:precursorMz
                 precursorCharge:precursorCharge
                           error:error];
}

- (MPGOSignalArray *)mzArray        { return self.signalArrays[@"mz"]; }
- (MPGOSignalArray *)intensityArray { return self.signalArrays[@"intensity"]; }

- (BOOL)writeAdditionalAttributesToGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    if (![group setIntegerAttribute:@"ms_level" value:(int64_t)_msLevel error:error]) return NO;
    if (![group setIntegerAttribute:@"polarity" value:(int64_t)_polarity error:error]) return NO;
    if (_scanWindow) {
        MPGOHDF5Dataset *d = [group createDatasetNamed:@"_scan_window"
                                              precision:MPGOPrecisionFloat64
                                                 length:2
                                              chunkSize:0
                                       compressionLevel:0
                                                  error:error];
        if (!d) return NO;
        double sw[2] = { _scanWindow.minimum, _scanWindow.maximum };
        if (![d writeData:[NSData dataWithBytes:sw length:sizeof(sw)] error:error]) return NO;
    }
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    BOOL exists = NO;
    _msLevel  = (NSUInteger)[group integerAttributeNamed:@"ms_level"
                                                  exists:&exists error:error];
    _polarity = (MPGOPolarity)[group integerAttributeNamed:@"polarity"
                                                    exists:&exists error:error];
    if ([group hasChildNamed:@"_scan_window"]) {
        MPGOHDF5Dataset *d = [group openDatasetNamed:@"_scan_window" error:error];
        NSData *data = [d readDataWithError:error];
        if (!data) return NO;
        const double *p = data.bytes;
        _scanWindow = [MPGOValueRange rangeWithMinimum:p[0] maximum:p[1]];
    }
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGOMassSpectrum class]]) return NO;
    MPGOMassSpectrum *o = (MPGOMassSpectrum *)other;
    if (_msLevel != o.msLevel) return NO;
    if (_polarity != o.polarity) return NO;
    if ((_scanWindow || o.scanWindow) && ![_scanWindow isEqual:o.scanWindow]) return NO;
    if (_activationMethod != o.activationMethod) return NO;
    if ((_isolationWindow || o.isolationWindow)
        && ![_isolationWindow isEqual:o.isolationWindow]) return NO;
    return YES;
}

@end
