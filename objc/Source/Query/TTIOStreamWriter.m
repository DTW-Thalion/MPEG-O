/*
 * TTIOStreamWriter.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOStreamWriter
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Query/TTIOStreamWriter.h
 *
 * Incremental writer that buffers spectra in memory and rewrites the
 * .tio file on every -flushWithError: so the run group always
 * reflects the buffered set. Whole-file regenerative flush keeps the
 * implementation simple and the file valid after each call.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOStreamWriter.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOStreamWriter
{
    NSString               *_path;
    NSString               *_runName;
    TTIOAcquisitionMode     _mode;
    TTIOInstrumentConfig   *_config;
    NSMutableArray<TTIOMassSpectrum *> *_buffer;
    BOOL                    _closed;
}

- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                 acquisitionMode:(TTIOAcquisitionMode)mode
                instrumentConfig:(TTIOInstrumentConfig *)config
                           error:(NSError **)error
{
    self = [super init];
    if (self) {
        _path    = [path copy];
        _runName = [runName copy];
        _mode    = mode;
        _config  = config;
        _buffer  = [NSMutableArray array];
        _closed  = NO;

        // Create the file with an empty run group as a starting point.
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:error];
        if (!f) return nil;
        [f close];
    }
    return self;
}

- (NSUInteger)spectrumCount { return _buffer.count; }

- (BOOL)appendSpectrum:(TTIOMassSpectrum *)spectrum error:(NSError **)error
{
    if (_closed) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"writer already closed");
        return NO;
    }
    [_buffer addObject:spectrum];
    return YES;
}

- (BOOL)flushWithError:(NSError **)error
{
    if (_closed) return YES;
    TTIOAcquisitionRun *run =
        [[TTIOAcquisitionRun alloc] initWithSpectra:_buffer
                                    acquisitionMode:_mode
                                   instrumentConfig:_config];

    // Whole-file regenerative flush: recreate the file each flush so the
    // run group always reflects every buffered spectrum.
    TTIOHDF5File *f = [TTIOHDF5File createAtPath:_path error:error];
    if (!f) return NO;
    if (![run writeToGroup:[f rootGroup] name:_runName error:error]) {
        [f close];
        return NO;
    }
    return [f close];
}

- (BOOL)flushAndCloseWithError:(NSError **)error
{
    BOOL ok = [self flushWithError:error];
    _closed = YES;
    return ok;
}

@end
