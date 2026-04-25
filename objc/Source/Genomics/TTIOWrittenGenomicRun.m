#import "TTIOWrittenGenomicRun.h"

@implementation TTIOWrittenGenomicRun

- (instancetype)initWithAcquisitionMode:(TTIOAcquisitionMode)mode
                            referenceUri:(NSString *)referenceUri
                                platform:(NSString *)platform
                              sampleName:(NSString *)sampleName
                                positions:(NSData *)positions
                         mappingQualities:(NSData *)mappingQualities
                                    flags:(NSData *)flags
                                sequences:(NSData *)sequences
                                qualities:(NSData *)qualities
                                  offsets:(NSData *)offsets
                                  lengths:(NSData *)lengths
                                   cigars:(NSArray<NSString *> *)cigars
                                readNames:(NSArray<NSString *> *)readNames
                          mateChromosomes:(NSArray<NSString *> *)mateChromosomes
                            matePositions:(NSData *)matePositions
                          templateLengths:(NSData *)templateLengths
                              chromosomes:(NSArray<NSString *> *)chromosomes
                       signalCompression:(TTIOCompression)signalCompression
{
    self = [super init];
    if (self) {
        _acquisitionMode      = mode;
        _referenceUri         = [referenceUri copy];
        _platform             = [platform copy];
        _sampleName           = [sampleName copy];
        _positionsData        = [positions copy];
        _mappingQualitiesData = [mappingQualities copy];
        _flagsData            = [flags copy];
        _sequencesData        = [sequences copy];
        _qualitiesData        = [qualities copy];
        _offsetsData          = [offsets copy];
        _lengthsData          = [lengths copy];
        _cigars               = [cigars copy];
        _readNames            = [readNames copy];
        _mateChromosomes      = [mateChromosomes copy];
        _matePositionsData    = [matePositions copy];
        _templateLengthsData  = [templateLengths copy];
        _chromosomes          = [chromosomes copy];
        _signalCompression    = signalCompression;
    }
    return self;
}

- (NSUInteger)readCount
{
    return _offsetsData.length / sizeof(uint64_t);
}

@end
