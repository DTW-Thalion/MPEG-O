#import "MPGOEncodingSpec.h"

@implementation MPGOEncodingSpec

- (instancetype)initWithPrecision:(MPGOPrecision)precision
             compressionAlgorithm:(MPGOCompression)compression
                        byteOrder:(MPGOByteOrder)byteOrder
{
    self = [super init];
    if (self) {
        _precision            = precision;
        _compressionAlgorithm = compression;
        _byteOrder            = byteOrder;
    }
    return self;
}

+ (instancetype)specWithPrecision:(MPGOPrecision)precision
             compressionAlgorithm:(MPGOCompression)compression
                        byteOrder:(MPGOByteOrder)byteOrder
{
    return [[self alloc] initWithPrecision:precision
                      compressionAlgorithm:compression
                                 byteOrder:byteOrder];
}

- (NSUInteger)elementSize
{
    switch (_precision) {
        case MPGOPrecisionFloat32:    return 4;
        case MPGOPrecisionFloat64:    return 8;
        case MPGOPrecisionInt32:      return 4;
        case MPGOPrecisionInt64:      return 8;
        case MPGOPrecisionUInt32:     return 4;
        case MPGOPrecisionComplex128: return 16;
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
    MPGOPrecision   p = (MPGOPrecision)  [coder decodeIntegerForKey:@"precision"];
    MPGOCompression c = (MPGOCompression)[coder decodeIntegerForKey:@"compressionAlgorithm"];
    MPGOByteOrder   b = (MPGOByteOrder)  [coder decodeIntegerForKey:@"byteOrder"];
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
    if (![other isKindOfClass:[MPGOEncodingSpec class]]) return NO;
    MPGOEncodingSpec *s = (MPGOEncodingSpec *)other;
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
