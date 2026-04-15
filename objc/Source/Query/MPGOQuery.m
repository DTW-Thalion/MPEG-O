#import "MPGOQuery.h"
#import "Run/MPGOSpectrumIndex.h"
#import "ValueClasses/MPGOValueRange.h"

@implementation MPGOQuery
{
    MPGOSpectrumIndex *_index;

    BOOL              _hasRtRange;
    MPGOValueRange   *_rtRange;
    BOOL              _hasMsLevel;
    uint8_t           _msLevel;
    BOOL              _hasPolarity;
    MPGOPolarity      _polarity;
    BOOL              _hasPrecMzRange;
    MPGOValueRange   *_precMzRange;
    BOOL              _hasBasePeakMin;
    double            _basePeakMin;
}

+ (instancetype)queryOnIndex:(MPGOSpectrumIndex *)index
{
    MPGOQuery *q = [[self alloc] init];
    q->_index = index;
    return q;
}

- (MPGOQuery *)withRetentionTimeRange:(MPGOValueRange *)range
{
    _hasRtRange = YES; _rtRange = range; return self;
}

- (MPGOQuery *)withMsLevel:(uint8_t)level
{
    _hasMsLevel = YES; _msLevel = level; return self;
}

- (MPGOQuery *)withPolarity:(MPGOPolarity)polarity
{
    _hasPolarity = YES; _polarity = polarity; return self;
}

- (MPGOQuery *)withPrecursorMzRange:(MPGOValueRange *)range
{
    _hasPrecMzRange = YES; _precMzRange = range; return self;
}

- (MPGOQuery *)withBasePeakIntensityAtLeast:(double)threshold
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
