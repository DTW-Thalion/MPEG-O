#import "TTIOQuery.h"
#import "Run/TTIOSpectrumIndex.h"
#import "ValueClasses/TTIOValueRange.h"

@implementation TTIOQuery
{
    TTIOSpectrumIndex *_index;

    BOOL              _hasRtRange;
    TTIOValueRange   *_rtRange;
    BOOL              _hasMsLevel;
    uint8_t           _msLevel;
    BOOL              _hasPolarity;
    TTIOPolarity      _polarity;
    BOOL              _hasPrecMzRange;
    TTIOValueRange   *_precMzRange;
    BOOL              _hasBasePeakMin;
    double            _basePeakMin;
}

+ (instancetype)queryOnIndex:(TTIOSpectrumIndex *)index
{
    TTIOQuery *q = [[self alloc] init];
    q->_index = index;
    return q;
}

- (TTIOQuery *)withRetentionTimeRange:(TTIOValueRange *)range
{
    _hasRtRange = YES; _rtRange = range; return self;
}

- (TTIOQuery *)withMsLevel:(uint8_t)level
{
    _hasMsLevel = YES; _msLevel = level; return self;
}

- (TTIOQuery *)withPolarity:(TTIOPolarity)polarity
{
    _hasPolarity = YES; _polarity = polarity; return self;
}

- (TTIOQuery *)withPrecursorMzRange:(TTIOValueRange *)range
{
    _hasPrecMzRange = YES; _precMzRange = range; return self;
}

- (TTIOQuery *)withBasePeakIntensityAtLeast:(double)threshold
{
    _hasBasePeakMin = YES; _basePeakMin = threshold; return self;
}

- (NSIndexSet *)matchingIndices
{
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    NSUInteger n = _index.count;
    for (NSUInteger i = 0; i < n; i++) {
        if (_hasRtRange && ![_rtRange containsValue:[_index retentionTimeAt:i]]) continue;
        if (_hasMsLevel && [_index msLevelAt:i] != _msLevel) continue;
        if (_hasPolarity && [_index polarityAt:i] != _polarity) continue;
        if (_hasPrecMzRange && ![_precMzRange containsValue:[_index precursorMzAt:i]]) continue;
        if (_hasBasePeakMin && [_index basePeakIntensityAt:i] < _basePeakMin) continue;
        [out addIndex:i];
    }
    return out;
}

@end
