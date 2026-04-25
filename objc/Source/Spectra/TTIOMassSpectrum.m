#import "TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOMassSpectrum

- (instancetype)initWithMzArray:(TTIOSignalArray *)mz
                 intensityArray:(TTIOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(TTIOPolarity)polarity
                     scanWindow:(TTIOValueRange *)scanWindow
               activationMethod:(TTIOActivationMethod)activationMethod
                isolationWindow:(TTIOIsolationWindow *)isolationWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error
{
    if (mz.length != intensity.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOMassSpectrum: mz length (%lu) != intensity length (%lu)",
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

- (instancetype)initWithMzArray:(TTIOSignalArray *)mz
                 intensityArray:(TTIOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(TTIOPolarity)polarity
                     scanWindow:(TTIOValueRange *)scanWindow
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
                activationMethod:TTIOActivationMethodNone
                 isolationWindow:nil
                   indexPosition:indexPosition
                 scanTimeSeconds:scanTime
                     precursorMz:precursorMz
                 precursorCharge:precursorCharge
                           error:error];
}

- (TTIOSignalArray *)mzArray        { return self.signalArrays[@"mz"]; }
- (TTIOSignalArray *)intensityArray { return self.signalArrays[@"intensity"]; }

- (BOOL)writeAdditionalAttributesToGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    if (![group setIntegerAttribute:@"ms_level" value:(int64_t)_msLevel error:error]) return NO;
    if (![group setIntegerAttribute:@"polarity" value:(int64_t)_polarity error:error]) return NO;
    if (_scanWindow) {
        TTIOHDF5Dataset *d = [group createDatasetNamed:@"_scan_window"
                                              precision:TTIOPrecisionFloat64
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

- (BOOL)readAdditionalAttributesFromGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    BOOL exists = NO;
    _msLevel  = (NSUInteger)[group integerAttributeNamed:@"ms_level"
                                                  exists:&exists error:error];
    _polarity = (TTIOPolarity)[group integerAttributeNamed:@"polarity"
                                                    exists:&exists error:error];
    if ([group hasChildNamed:@"_scan_window"]) {
        TTIOHDF5Dataset *d = [group openDatasetNamed:@"_scan_window" error:error];
        NSData *data = [d readDataWithError:error];
        if (!data) return NO;
        const double *p = data.bytes;
        _scanWindow = [TTIOValueRange rangeWithMinimum:p[0] maximum:p[1]];
    }
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[TTIOMassSpectrum class]]) return NO;
    TTIOMassSpectrum *o = (TTIOMassSpectrum *)other;
    if (_msLevel != o.msLevel) return NO;
    if (_polarity != o.polarity) return NO;
    if ((_scanWindow || o.scanWindow) && ![_scanWindow isEqual:o.scanWindow]) return NO;
    if (_activationMethod != o.activationMethod) return NO;
    if ((_isolationWindow || o.isolationWindow)
        && ![_isolationWindow isEqual:o.isolationWindow]) return NO;
    return YES;
}

@end
