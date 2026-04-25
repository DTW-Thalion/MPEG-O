#import "TTIOGenomicIndex.h"

@implementation TTIOGenomicIndex {
    NSData *_offsetsData;
    NSData *_lengthsData;
    NSArray<NSString *> *_chromosomes;
    NSData *_positionsData;
    NSData *_mappingQualitiesData;
    NSData *_flagsData;
}

- (instancetype)initWithOffsets:(NSData *)offsets
                         lengths:(NSData *)lengths
                     chromosomes:(NSArray<NSString *> *)chromosomes
                       positions:(NSData *)positions
                mappingQualities:(NSData *)mappingQualities
                            flags:(NSData *)flags
{
    self = [super init];
    if (self) {
        _offsetsData          = [offsets copy];
        _lengthsData          = [lengths copy];
        _chromosomes          = [chromosomes copy];
        _positionsData        = [positions copy];
        _mappingQualitiesData = [mappingQualities copy];
        _flagsData            = [flags copy];
    }
    return self;
}

- (NSUInteger)count
{
    return _offsetsData.length / sizeof(uint64_t);
}

- (uint64_t)offsetAt:(NSUInteger)index
{
    return ((const uint64_t *)_offsetsData.bytes)[index];
}

- (uint32_t)lengthAt:(NSUInteger)index
{
    return ((const uint32_t *)_lengthsData.bytes)[index];
}

- (int64_t)positionAt:(NSUInteger)index
{
    return ((const int64_t *)_positionsData.bytes)[index];
}

- (uint8_t)mappingQualityAt:(NSUInteger)index
{
    return ((const uint8_t *)_mappingQualitiesData.bytes)[index];
}

- (uint32_t)flagsAt:(NSUInteger)index
{
    return ((const uint32_t *)_flagsData.bytes)[index];
}

- (NSString *)chromosomeAt:(NSUInteger)index
{
    return _chromosomes[index];
}

- (NSIndexSet *)indicesForRegion:(NSString *)chromosome
                            start:(int64_t)start
                              end:(int64_t)end
{
    NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
    NSUInteger n = self.count;
    const int64_t *positions = (const int64_t *)_positionsData.bytes;
    for (NSUInteger i = 0; i < n; i++) {
        if ([_chromosomes[i] isEqualToString:chromosome]
            && positions[i] >= start
            && positions[i] < end) {
            [result addIndex:i];
        }
    }
    return result;
}

- (NSIndexSet *)indicesForUnmapped
{
    return [self indicesForFlag:0x4];
}

- (NSIndexSet *)indicesForFlag:(uint32_t)flagMask
{
    NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
    NSUInteger n = self.count;
    const uint32_t *flags = (const uint32_t *)_flagsData.bytes;
    for (NSUInteger i = 0; i < n; i++) {
        if ((flags[i] & flagMask) != 0) {
            [result addIndex:i];
        }
    }
    return result;
}

- (BOOL)writeToGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    [NSException raise:NSInternalInconsistencyException
                format:@"TTIOGenomicIndex.writeToGroup: implemented in a follow-up commit"];
    return NO;
}

+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    [NSException raise:NSInternalInconsistencyException
                format:@"TTIOGenomicIndex.readFromGroup: implemented in a follow-up commit"];
    return nil;
}

@end
