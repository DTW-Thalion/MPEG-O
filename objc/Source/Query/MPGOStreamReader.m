#import "MPGOStreamReader.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOStreamReader
{
    MPGOHDF5File       *_file;
    MPGOAcquisitionRun *_run;
    NSUInteger          _position;
}

- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                           error:(NSError **)error
{
    self = [super init];
    if (self) {
        _file = [MPGOHDF5File openReadOnlyAtPath:path error:error];
        if (!_file) return nil;
        _run = [MPGOAcquisitionRun readFromGroup:[_file rootGroup]
                                            name:runName
                                           error:error];
        if (!_run) return nil;
        _position = 0;
    }
    return self;
}

- (NSUInteger)totalCount      { return [_run count]; }
- (NSUInteger)currentPosition { return _position; }
- (BOOL)atEnd                  { return _position >= [_run count]; }

- (MPGOMassSpectrum *)nextSpectrumWithError:(NSError **)error
{
    if ([self atEnd]) return nil;
    MPGOMassSpectrum *s = [_run spectrumAtIndex:_position error:error];
    if (s) _position++;
    return s;
}

- (void)reset { _position = 0; }

- (void)close { [_file close]; _file = nil; _run = nil; }

@end
