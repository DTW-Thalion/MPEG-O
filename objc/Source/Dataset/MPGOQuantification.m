#import "MPGOQuantification.h"

@implementation MPGOQuantification

- (instancetype)initWithChemicalEntity:(NSString *)entity
                             sampleRef:(NSString *)sampleRef
                             abundance:(double)abundance
                   normalizationMethod:(NSString *)method
{
    self = [super init];
    if (self) {
        _chemicalEntity      = [entity copy];
        _sampleRef           = [sampleRef copy];
        _abundance           = abundance;
        _normalizationMethod = [method copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (NSDictionary *)asPlist
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"chemical_entity"] = _chemicalEntity ?: @"";
    d[@"sample_ref"]      = _sampleRef ?: @"";
    d[@"abundance"]       = @(_abundance);
    if (_normalizationMethod) d[@"normalization_method"] = _normalizationMethod;
    return d;
}

+ (instancetype)fromPlist:(NSDictionary *)plist
{
    return [[self alloc] initWithChemicalEntity:plist[@"chemical_entity"]
                                       sampleRef:plist[@"sample_ref"]
                                       abundance:[plist[@"abundance"] doubleValue]
                             normalizationMethod:plist[@"normalization_method"]];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOQuantification class]]) return NO;
    MPGOQuantification *o = (MPGOQuantification *)other;
    if (![_chemicalEntity isEqualToString:o.chemicalEntity]) return NO;
    if (![_sampleRef isEqualToString:o.sampleRef]) return NO;
    if (_abundance != o.abundance) return NO;
    if ((_normalizationMethod || o.normalizationMethod) &&
        ![_normalizationMethod isEqualToString:o.normalizationMethod]) return NO;
    return YES;
}

- (NSUInteger)hash { return [_chemicalEntity hash] ^ [_sampleRef hash]; }

@end
