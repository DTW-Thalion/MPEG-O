#import "MPGOValueRange.h"

@implementation MPGOValueRange

- (instancetype)initWithMinimum:(double)minimum maximum:(double)maximum
{
    self = [super init];
    if (self) {
        _minimum = minimum;
        _maximum = maximum;
    }
    return self;
}

+ (instancetype)rangeWithMinimum:(double)minimum maximum:(double)maximum
{
    return [[self alloc] initWithMinimum:minimum maximum:maximum];
}

- (double)span
{
    return _maximum - _minimum;
}

- (BOOL)containsValue:(double)value
{
    return value >= _minimum && value <= _maximum;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    // Immutable — return self.
    return self;
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _minimum = [coder decodeDoubleForKey:@"minimum"];
        _maximum = [coder decodeDoubleForKey:@"maximum"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_minimum forKey:@"minimum"];
    [coder encodeDouble:_maximum forKey:@"maximum"];
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOValueRange class]]) return NO;
    MPGOValueRange *r = (MPGOValueRange *)other;
    return r.minimum == _minimum && r.maximum == _maximum;
}

- (NSUInteger)hash
{
    NSUInteger h = 17;
    h = h * 31 + (NSUInteger)_minimum;
    h = h * 31 + (NSUInteger)_maximum;
    return h;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MPGOValueRange [%g, %g]>", _minimum, _maximum];
}

@end
