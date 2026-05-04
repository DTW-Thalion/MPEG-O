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
    return [self initWithAcquisitionMode:mode
                            referenceUri:referenceUri
                                platform:platform
                              sampleName:sampleName
                                positions:positions
                         mappingQualities:mappingQualities
                                    flags:flags
                                sequences:sequences
                                qualities:qualities
                                  offsets:offsets
                                  lengths:lengths
                                   cigars:cigars
                                readNames:readNames
                          mateChromosomes:mateChromosomes
                            matePositions:matePositions
                          templateLengths:templateLengths
                              chromosomes:chromosomes
                       signalCompression:signalCompression
                     signalCodecOverrides:@{}];
}

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
                     signalCodecOverrides:(NSDictionary<NSString *, NSNumber *> *)signalCodecOverrides
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
        _signalCodecOverrides = signalCodecOverrides
            ? [signalCodecOverrides copy]
            : @{};
        _provenanceRecords    = @[];
        // L3 (Task #82 Phase B.1, 2026-05-01): embedReference now
        // defaults to NO so chr22-style benchmarks don't carry the
        // ~10 MB embedded reference blob by default. CRAM 3.1's
        // default is also external-reference; users who want
        // self-contained .tio files set embedReference = YES
        // explicitly.
        _embedReference        = NO;
        _referenceChromSeqs    = nil;
        _externalReferencePath = nil;
        // v1.7 #11: default NO → writer uses inline_v2 path when
        // native libttio_rans is linked (TTIOCompressionMateInlineV2).
        _optDisableInlineMateInfoV2 = NO;
        // v1.8 #11: default NO → writer uses refdiff_v2 group layout
        // when native libttio_rans is linked and run is eligible.
        _optDisableRefDiffV2 = NO;
        // v1.8 #11 ch3: default NO → writer emits NAME_TOKENIZED_V2
        // (codec id 15) for read_names when native libttio_rans is linked.
        _optDisableNameTokenizedV2 = NO;
    }
    return self;
}

- (NSUInteger)readCount
{
    return _offsetsData.length / sizeof(uint64_t);
}

@end
