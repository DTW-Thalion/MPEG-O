/*
 * TTIOIRSpectrum.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOIRSpectrum
 * Inherits From: TTIOSpectrum : NSObject
 * Declared In:   Spectra/TTIOIRSpectrum.h
 *
 * 1-D mid-IR spectrum (transmittance or absorbance).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOIRSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOIRSpectrum

- (instancetype)initWithWavenumberArray:(TTIOSignalArray *)wavenumbers
                         intensityArray:(TTIOSignalArray *)intensity
                                   mode:(TTIOIRMode)mode
                        resolutionCmInv:(double)resolutionCmInv
                          numberOfScans:(NSUInteger)numberOfScans
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error
{
    if (wavenumbers.length != intensity.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOIRSpectrum: wavenumber length != intensity length");
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

- (TTIOSignalArray *)wavenumberArray { return self.signalArrays[@"wavenumber"]; }
- (TTIOSignalArray *)intensityArray  { return self.signalArrays[@"intensity"]; }

- (BOOL)writeAdditionalAttributesToGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    NSString *modeStr = (_mode == TTIOIRModeAbsorbance) ? @"absorbance" : @"transmittance";
    if (![group setAttributeValue:modeStr forName:@"ir_mode" error:error]) return NO;
    if (![group setAttributeValue:@((int64_t)_numberOfScans)
                          forName:@"number_of_scans" error:error]) return NO;
    id<TTIOStorageDataset> d = [group createDatasetNamed:@"_resolution_cm_inv"
                                               precision:TTIOPrecisionFloat64
                                                  length:1
                                               chunkSize:0
                                             compression:TTIOCompressionZlib
                                        compressionLevel:0
                                                   error:error];
    if (!d) return NO;
    double buf[1] = { _resolutionCmInv };
    return [d writeAll:[NSData dataWithBytes:buf length:sizeof(buf)] error:error];
}

- (BOOL)readAdditionalAttributesFromGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    NSString *modeStr = [group attributeValueForName:@"ir_mode" error:error];
    _mode = [modeStr isEqualToString:@"absorbance"] ? TTIOIRModeAbsorbance
                                                    : TTIOIRModeTransmittance;
    NSNumber *ns = [group attributeValueForName:@"number_of_scans" error:error];
    if (ns) _numberOfScans = (NSUInteger)[ns longLongValue];
    id<TTIOStorageDataset> d = [group openDatasetNamed:@"_resolution_cm_inv" error:error];
    if (!d) return NO;
    NSData *data = [d readAll:error];
    if (!data) return NO;
    _resolutionCmInv = ((const double *)data.bytes)[0];
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[TTIOIRSpectrum class]]) return NO;
    TTIOIRSpectrum *o = (TTIOIRSpectrum *)other;
    if (_mode            != o.mode)            return NO;
    if (_resolutionCmInv != o.resolutionCmInv) return NO;
    if (_numberOfScans   != o.numberOfScans)   return NO;
    return YES;
}

@end
