#import "TTIOStreamReader.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOStreamReader
{
    TTIOHDF5File       *_file;
    TTIOAcquisitionRun *_run;
    NSUInteger          _position;
}

- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                           error:(NSError **)error
{
    self = [super init];
    if (self) {
        _file = [TTIOHDF5File openReadOnlyAtPath:path error:error];
        if (!_file) return nil;
        _run = [TTIOAcquisitionRun readFromGroup:[_file rootGroup]
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

- (TTIOMassSpectrum *)nextSpectrumWithError:(NSError **)error
{
    if ([self atEnd]) return nil;
    TTIOMassSpectrum *s = [_run spectrumAtIndex:_position error:error];
    if (s) _position++;
    return s;
}

- (void)reset { _position = 0; }

- (void)close { [_file close]; _file = nil; _run = nil; }

@end
