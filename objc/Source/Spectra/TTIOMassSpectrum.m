/*
 * TTIOMassSpectrum.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOMassSpectrum
 * Inherits From: TTIOSpectrum : NSObject
 * Declared In:   Spectra/TTIOMassSpectrum.h
 *
 * Mass spectrum with m/z + intensity + MS level + polarity + scan
 * window + optional precursor activation / isolation metadata.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
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

- (BOOL)writeAdditionalAttributesToGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    if (![group setAttributeValue:@((int64_t)_msLevel) forName:@"ms_level" error:error]) return NO;
    if (![group setAttributeValue:@((int64_t)_polarity) forName:@"polarity" error:error]) return NO;
    if (_scanWindow) {
        id<TTIOStorageDataset> d = [group createDatasetNamed:@"_scan_window"
                                                   precision:TTIOPrecisionFloat64
                                                      length:2
                                                   chunkSize:0
                                                 compression:TTIOCompressionZlib
                                            compressionLevel:0
                                                       error:error];
        if (!d) return NO;
        double sw[2] = { _scanWindow.minimum, _scanWindow.maximum };
        if (![d writeAll:[NSData dataWithBytes:sw length:sizeof(sw)] error:error]) return NO;
    }
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    NSNumber *ms = [group attributeValueForName:@"ms_level" error:error];
    if (ms) _msLevel = (NSUInteger)[ms longLongValue];
    NSNumber *pol = [group attributeValueForName:@"polarity" error:error];
    if (pol) _polarity = (TTIOPolarity)[pol longLongValue];
    if ([group hasChildNamed:@"_scan_window"]) {
        id<TTIOStorageDataset> d = [group openDatasetNamed:@"_scan_window" error:error];
        NSData *data = [d readAll:error];
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
