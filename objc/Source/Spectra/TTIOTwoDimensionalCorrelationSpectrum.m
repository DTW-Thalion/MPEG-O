/*
 * TTIOTwoDimensionalCorrelationSpectrum.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOTwoDimensionalCorrelationSpectrum
 * Inherits From: TTIOSpectrum : NSObject
 * Declared In:   Spectra/TTIOTwoDimensionalCorrelationSpectrum.h
 *
 * Noda 2-D correlation spectrum (2D-COS): synchronous + asynchronous
 * correlation matrices keyed on a shared spectral-variable axis.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOTwoDimensionalCorrelationSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOTwoDimensionalCorrelationSpectrum

- (instancetype)initWithSynchronousMatrix:(NSData *)sync
                       asynchronousMatrix:(NSData *)asyn
                               matrixSize:(NSUInteger)size
                             variableAxis:(TTIOAxisDescriptor *)axis
                             perturbation:(NSString *)perturbation
                         perturbationUnit:(NSString *)perturbationUnit
                           sourceModality:(NSString *)sourceModality
                            indexPosition:(NSUInteger)indexPosition
                                    error:(NSError **)error
{
    NSUInteger expected = size * size * sizeof(double);
    if (sync.length != expected) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDimensionalCorrelationSpectrum: synchronousMatrix bytes %lu != size*size*8 = %lu",
            (unsigned long)sync.length, (unsigned long)expected);
        return nil;
    }
    if (asyn.length != expected) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOTwoDimensionalCorrelationSpectrum: asynchronousMatrix bytes %lu != size*size*8 = %lu",
            (unsigned long)asyn.length, (unsigned long)expected);
        return nil;
    }

    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    TTIOSignalArray *syncFlat = [[TTIOSignalArray alloc] initWithBuffer:sync
                                                                  length:size * size
                                                                encoding:enc
                                                                    axis:nil];
    TTIOSignalArray *asynFlat = [[TTIOSignalArray alloc] initWithBuffer:asyn
                                                                  length:size * size
                                                                encoding:enc
                                                                    axis:nil];
    NSDictionary *arrays = @{
        @"synchronous_matrix":  syncFlat,
        @"asynchronous_matrix": asynFlat,
    };
    self = [super initWithSignalArrays:arrays
                                  axes:(axis ? @[ axis ] : @[])
                         indexPosition:indexPosition
                       scanTimeSeconds:0
                           precursorMz:0
                       precursorCharge:0];
    if (self) {
        _synchronousMatrix  = [sync copy];
        _asynchronousMatrix = [asyn copy];
        _matrixSize         = size;
        _variableAxis       = axis;
        _perturbation       = [perturbation copy] ?: @"";
        _perturbationUnit   = [perturbationUnit copy] ?: @"";
        _sourceModality     = [sourceModality copy] ?: @"";
    }
    return self;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[TTIOTwoDimensionalCorrelationSpectrum class]]) return NO;
    TTIOTwoDimensionalCorrelationSpectrum *o = (TTIOTwoDimensionalCorrelationSpectrum *)other;
    if (_matrixSize != o.matrixSize) return NO;
    if (![_synchronousMatrix isEqualToData:o.synchronousMatrix]) return NO;
    if (![_asynchronousMatrix isEqualToData:o.asynchronousMatrix]) return NO;
    if (![_perturbation isEqualToString:o.perturbation]) return NO;
    if (![_perturbationUnit isEqualToString:o.perturbationUnit]) return NO;
    if (![_sourceModality isEqualToString:o.sourceModality]) return NO;
    return YES;
}

@end
