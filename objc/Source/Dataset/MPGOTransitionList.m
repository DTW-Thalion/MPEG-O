#import "MPGOTransitionList.h"
#import "ValueClasses/MPGOValueRange.h"

@implementation MPGOTransition

- (instancetype)initWithPrecursorMz:(double)precursor
                          productMz:(double)product
                    collisionEnergy:(double)ce
                retentionTimeWindow:(MPGOValueRange *)window
{
    self = [super init];
    if (self) {
        _precursorMz = precursor;
        _productMz   = product;
        _collisionEnergy = ce;
        _retentionTimeWindow = window;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOTransition class]]) return NO;
    MPGOTransition *o = (MPGOTransition *)other;
    if (_precursorMz != o.precursorMz) return NO;
    if (_productMz != o.productMz) return NO;
    if (_collisionEnergy != o.collisionEnergy) return NO;
    if ((_retentionTimeWindow || o.retentionTimeWindow) &&
        ![_retentionTimeWindow isEqual:o.retentionTimeWindow]) return NO;
    return YES;
}

- (NSUInteger)hash { return (NSUInteger)(_precursorMz * 1000) ^ (NSUInteger)(_productMz * 1000); }

@end

@implementation MPGOTransitionList

- (instancetype)initWithTransitions:(NSArray<MPGOTransition *> *)transitions
{
    self = [super init];
    if (self) {
        _transitions = [transitions copy] ?: @[];
    }
    return self;
}

- (NSUInteger)count { return _transitions.count; }
- (MPGOTransition *)transitionAtIndex:(NSUInteger)index { return _transitions[index]; }

- (NSDictionary *)asPlist
{
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:_transitions.count];
    for (MPGOTransition *t in _transitions) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"precursor_mz"]    = @(t.precursorMz);
        d[@"product_mz"]      = @(t.productMz);
        d[@"collision_energy"] = @(t.collisionEnergy);
        if (t.retentionTimeWindow) {
            d[@"rt_window_min"] = @(t.retentionTimeWindow.minimum);
            d[@"rt_window_max"] = @(t.retentionTimeWindow.maximum);
        }
        [arr addObject:d];
    }
    return @{ @"transitions": arr };
}

+ (instancetype)fromPlist:(NSDictionary *)plist
{
    NSArray *arr = plist[@"transitions"];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:arr.count];
    for (NSDictionary *d in arr) {
        MPGOValueRange *w = nil;
        if (d[@"rt_window_min"]) {
            w = [MPGOValueRange rangeWithMinimum:[d[@"rt_window_min"] doubleValue]
                                          maximum:[d[@"rt_window_max"] doubleValue]];
        }
        MPGOTransition *t =
            [[MPGOTransition alloc] initWithPrecursorMz:[d[@"precursor_mz"] doubleValue]
                                              productMz:[d[@"product_mz"] doubleValue]
                                        collisionEnergy:[d[@"collision_energy"] doubleValue]
                                    retentionTimeWindow:w];
        [out addObject:t];
    }
    return [[self alloc] initWithTransitions:out];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOTransitionList class]]) return NO;
    return [_transitions isEqualToArray:[(MPGOTransitionList *)other transitions]];
}

- (NSUInteger)hash { return _transitions.count; }

@end
