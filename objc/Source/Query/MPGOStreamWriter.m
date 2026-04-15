#import "MPGOStreamWriter.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOStreamWriter
{
    NSString               *_path;
    NSString               *_runName;
    MPGOAcquisitionMode     _mode;
    MPGOInstrumentConfig   *_config;
    NSMutableArray<MPGOMassSpectrum *> *_buffer;
    BOOL                    _closed;
}

- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                 acquisitionMode:(MPGOAcquisitionMode)mode
                instrumentConfig:(MPGOInstrumentConfig *)config
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
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:error];
        if (!f) return nil;
        [f close];
    }
    return self;
}

- (NSUInteger)spectrumCount { return _buffer.count; }

- (BOOL)appendSpectrum:(MPGOMassSpectrum *)spectrum error:(NSError **)error
{
    if (_closed) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument, @"writer already closed");
        return NO;
    }
    [_buffer addObject:spectrum];
    return YES;
}

- (BOOL)flushWithError:(NSError **)error
{
    if (_closed) return YES;
    MPGOAcquisitionRun *run =
        [[MPGOAcquisitionRun alloc] initWithSpectra:_buffer
                                    acquisitionMode:_mode
                                   instrumentConfig:_config];

    // Whole-file regenerative flush: recreate the file each flush so the
    // run group always reflects every buffered spectrum.
    MPGOHDF5File *f = [MPGOHDF5File createAtPath:_path error:error];
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
