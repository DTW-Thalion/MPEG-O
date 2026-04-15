#import "MPGOProvenanceRecord.h"

@implementation MPGOProvenanceRecord

- (instancetype)initWithInputRefs:(NSArray<NSString *> *)inputs
                         software:(NSString *)software
                       parameters:(NSDictionary<NSString *, id> *)parameters
                       outputRefs:(NSArray<NSString *> *)outputs
                    timestampUnix:(int64_t)timestamp
{
    self = [super init];
    if (self) {
        _inputRefs     = [inputs copy] ?: @[];
        _software      = [software copy];
        _parameters    = [parameters copy] ?: @{};
        _outputRefs    = [outputs copy] ?: @[];
        _timestampUnix = timestamp;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)containsInputRef:(NSString *)ref
{
    return [_inputRefs containsObject:ref];
}

- (NSDictionary *)asPlist
{
    return @{ @"input_refs":     _inputRefs,
              @"software":       _software ?: @"",
              @"parameters":     _parameters,
              @"output_refs":    _outputRefs,
              @"timestamp_unix": @(_timestampUnix) };
}

+ (instancetype)fromPlist:(NSDictionary *)plist
{
    return [[self alloc] initWithInputRefs:plist[@"input_refs"]
                                  software:plist[@"software"]
                                parameters:plist[@"parameters"]
                                outputRefs:plist[@"output_refs"]
                             timestampUnix:[plist[@"timestamp_unix"] longLongValue]];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOProvenanceRecord class]]) return NO;
    MPGOProvenanceRecord *o = (MPGOProvenanceRecord *)other;
    return [_inputRefs isEqualToArray:o.inputRefs]
        && [_software isEqualToString:o.software]
        && [_parameters isEqualToDictionary:o.parameters]
        && [_outputRefs isEqualToArray:o.outputRefs]
        && _timestampUnix == o.timestampUnix;
}

- (NSUInteger)hash { return [_software hash] ^ (NSUInteger)_timestampUnix; }

@end
