#import "TTIOIsolationWindow.h"

@implementation TTIOIsolationWindow

- (instancetype)initWithTargetMz:(double)targetMz
                     lowerOffset:(double)lowerOffset
                     upperOffset:(double)upperOffset
{
    self = [super init];
    if (self) {
        _targetMz = targetMz;
        _lowerOffset = lowerOffset;
        _upperOffset = upperOffset;
    }
    return self;
}

+ (instancetype)windowWithTargetMz:(double)targetMz
                       lowerOffset:(double)lowerOffset
                       upperOffset:(double)upperOffset
{
    return [[self alloc] initWithTargetMz:targetMz
                              lowerOffset:lowerOffset
                              upperOffset:upperOffset];
}

- (double)lowerBound { return _targetMz - _lowerOffset; }
- (double)upperBound { return _targetMz + _upperOffset; }
- (double)width      { return _lowerOffset + _upperOffset; }

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
        _targetMz    = [coder decodeDoubleForKey:@"targetMz"];
        _lowerOffset = [coder decodeDoubleForKey:@"lowerOffset"];
        _upperOffset = [coder decodeDoubleForKey:@"upperOffset"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_targetMz    forKey:@"targetMz"];
    [coder encodeDouble:_lowerOffset forKey:@"lowerOffset"];
    [coder encodeDouble:_upperOffset forKey:@"upperOffset"];
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOIsolationWindow class]]) return NO;
    TTIOIsolationWindow *w = (TTIOIsolationWindow *)other;
    return w.targetMz == _targetMz
        && w.lowerOffset == _lowerOffset
        && w.upperOffset == _upperOffset;
}

- (NSUInteger)hash
{
    NSUInteger h = 17;
    h = h * 31 + (NSUInteger)_targetMz;
    h = h * 31 + (NSUInteger)_lowerOffset;
    h = h * 31 + (NSUInteger)_upperOffset;
    return h;
}

- (NSString *)description
{
    return [NSString stringWithFormat:
        @"<TTIOIsolationWindow target=%g [-%g, +%g]>",
        _targetMz, _lowerOffset, _upperOffset];
}

@end
