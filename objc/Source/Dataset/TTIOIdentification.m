#import "TTIOIdentification.h"

@implementation TTIOIdentification

- (instancetype)initWithRunName:(NSString *)runName
                  spectrumIndex:(NSUInteger)spectrumIndex
                 chemicalEntity:(NSString *)chemicalEntity
                confidenceScore:(double)score
                  evidenceChain:(NSArray<NSString *> *)evidence
{
    self = [super init];
    if (self) {
        _runName         = [runName copy];
        _spectrumIndex   = spectrumIndex;
        _chemicalEntity  = [chemicalEntity copy];
        _confidenceScore = score;
        _evidenceChain   = [evidence copy] ?: @[];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (NSDictionary *)asPlist
{
    return @{ @"run_name":         _runName,
              @"spectrum_index":   @(_spectrumIndex),
              @"chemical_entity":  _chemicalEntity,
              @"confidence_score": @(_confidenceScore),
              @"evidence_chain":   _evidenceChain };
}

+ (instancetype)fromPlist:(NSDictionary *)plist
{
    return [[self alloc] initWithRunName:plist[@"run_name"]
                           spectrumIndex:[plist[@"spectrum_index"] unsignedIntegerValue]
                          chemicalEntity:plist[@"chemical_entity"]
                         confidenceScore:[plist[@"confidence_score"] doubleValue]
                           evidenceChain:plist[@"evidence_chain"]];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOIdentification class]]) return NO;
    TTIOIdentification *o = (TTIOIdentification *)other;
    return [_runName isEqualToString:o.runName]
        && _spectrumIndex == o.spectrumIndex
        && [_chemicalEntity isEqualToString:o.chemicalEntity]
        && _confidenceScore == o.confidenceScore
        && [_evidenceChain isEqualToArray:o.evidenceChain];
}

- (NSUInteger)hash { return [_chemicalEntity hash] ^ _spectrumIndex; }

@end
