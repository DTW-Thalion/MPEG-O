#import "MPGOAxisDescriptor.h"

@implementation MPGOAxisDescriptor

- (instancetype)initWithName:(NSString *)name
                        unit:(NSString *)unit
                  valueRange:(MPGOValueRange *)valueRange
                samplingMode:(MPGOSamplingMode)samplingMode
{
    NSParameterAssert(name != nil);
    NSParameterAssert(unit != nil);
    NSParameterAssert(valueRange != nil);

    self = [super init];
    if (self) {
        _name         = [name copy];
        _unit         = [unit copy];
        _valueRange   = valueRange;
        _samplingMode = samplingMode;
    }
    return self;
}

+ (instancetype)descriptorWithName:(NSString *)name
                              unit:(NSString *)unit
                        valueRange:(MPGOValueRange *)valueRange
                      samplingMode:(MPGOSamplingMode)samplingMode
{
    return [[self alloc] initWithName:name
                                 unit:unit
                           valueRange:valueRange
                         samplingMode:samplingMode];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString       *name  = [coder decodeObjectForKey:@"name"];
    NSString       *unit  = [coder decodeObjectForKey:@"unit"];
    MPGOValueRange *range = [coder decodeObjectForKey:@"valueRange"];
    NSUInteger      mode  = (NSUInteger)[coder decodeIntegerForKey:@"samplingMode"];
    return [self initWithName:name unit:unit valueRange:range samplingMode:mode];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_name       forKey:@"name"];
    [coder encodeObject:_unit       forKey:@"unit"];
    [coder encodeObject:_valueRange forKey:@"valueRange"];
    [coder encodeInteger:(NSInteger)_samplingMode forKey:@"samplingMode"];
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOAxisDescriptor class]]) return NO;
    MPGOAxisDescriptor *a = (MPGOAxisDescriptor *)other;
    return [_name isEqualToString:a.name]
        && [_unit isEqualToString:a.unit]
        && [_valueRange isEqual:a.valueRange]
        && _samplingMode == a.samplingMode;
}

- (NSUInteger)hash
{
    return [_name hash] ^ [_unit hash] ^ [_valueRange hash];
}

@end
