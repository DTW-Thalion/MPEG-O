#import "TTIOEncodingSpec.h"

@implementation TTIOEncodingSpec

- (instancetype)initWithPrecision:(TTIOPrecision)precision
             compressionAlgorithm:(TTIOCompression)compression
                        byteOrder:(TTIOByteOrder)byteOrder
{
    self = [super init];
    if (self) {
        _precision            = precision;
        _compressionAlgorithm = compression;
        _byteOrder            = byteOrder;
    }
    return self;
}

+ (instancetype)specWithPrecision:(TTIOPrecision)precision
             compressionAlgorithm:(TTIOCompression)compression
                        byteOrder:(TTIOByteOrder)byteOrder
{
    return [[self alloc] initWithPrecision:precision
                      compressionAlgorithm:compression
                                 byteOrder:byteOrder];
}

- (NSUInteger)elementSize
{
    switch (_precision) {
        case TTIOPrecisionFloat32:    return 4;
        case TTIOPrecisionFloat64:    return 8;
        case TTIOPrecisionInt32:      return 4;
        case TTIOPrecisionInt64:      return 8;
        case TTIOPrecisionUInt32:     return 4;
        case TTIOPrecisionComplex128: return 16;
        case TTIOPrecisionUInt8:      return 1;
    }
    return 0;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder
{
    TTIOPrecision   p = (TTIOPrecision)  [coder decodeIntegerForKey:@"precision"];
    TTIOCompression c = (TTIOCompression)[coder decodeIntegerForKey:@"compressionAlgorithm"];
    TTIOByteOrder   b = (TTIOByteOrder)  [coder decodeIntegerForKey:@"byteOrder"];
    return [self initWithPrecision:p compressionAlgorithm:c byteOrder:b];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:(NSInteger)_precision            forKey:@"precision"];
    [coder encodeInteger:(NSInteger)_compressionAlgorithm forKey:@"compressionAlgorithm"];
    [coder encodeInteger:(NSInteger)_byteOrder            forKey:@"byteOrder"];
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOEncodingSpec class]]) return NO;
    TTIOEncodingSpec *s = (TTIOEncodingSpec *)other;
    return _precision == s.precision
        && _compressionAlgorithm == s.compressionAlgorithm
        && _byteOrder == s.byteOrder;
}

- (NSUInteger)hash
{
    return (NSUInteger)_precision * 31u
         + (NSUInteger)_compressionAlgorithm * 17u
         + (NSUInteger)_byteOrder;
}

@end
