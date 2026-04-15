#import "MPGOCVParam.h"

@implementation MPGOCVParam

- (instancetype)initWithOntologyRef:(NSString *)ontologyRef
                          accession:(NSString *)accession
                               name:(NSString *)name
                              value:(id)value
                               unit:(NSString *)unit
{
    NSParameterAssert(ontologyRef != nil);
    NSParameterAssert(accession   != nil);
    NSParameterAssert(name        != nil);

    self = [super init];
    if (self) {
        _ontologyRef = [ontologyRef copy];
        _accession   = [accession   copy];
        _name        = [name        copy];
        _value       = value ? [value copy] : nil;
        _unit        = unit  ? [unit  copy] : nil;
    }
    return self;
}

+ (instancetype)paramWithOntologyRef:(NSString *)ontologyRef
                           accession:(NSString *)accession
                                name:(NSString *)name
                               value:(id)value
                                unit:(NSString *)unit
{
    return [[self alloc] initWithOntologyRef:ontologyRef
                                   accession:accession
                                        name:name
                                       value:value
                                        unit:unit];
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
    NSString *ontologyRef = [coder decodeObjectForKey:@"ontologyRef"];
    NSString *accession   = [coder decodeObjectForKey:@"accession"];
    NSString *name        = [coder decodeObjectForKey:@"name"];
    id        value       = [coder decodeObjectForKey:@"value"];
    NSString *unit        = [coder decodeObjectForKey:@"unit"];
    return [self initWithOntologyRef:ontologyRef
                           accession:accession
                                name:name
                               value:value
                                unit:unit];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_ontologyRef forKey:@"ontologyRef"];
    [coder encodeObject:_accession   forKey:@"accession"];
    [coder encodeObject:_name        forKey:@"name"];
    [coder encodeObject:_value       forKey:@"value"];
    [coder encodeObject:_unit        forKey:@"unit"];
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOCVParam class]]) return NO;
    MPGOCVParam *p = (MPGOCVParam *)other;

    BOOL valueEq = (_value == p.value) || [_value isEqual:p.value];
    BOOL unitEq  = (_unit  == p.unit)  || [_unit  isEqual:p.unit];

    return [_ontologyRef isEqualToString:p.ontologyRef]
        && [_accession   isEqualToString:p.accession]
        && [_name        isEqualToString:p.name]
        && valueEq
        && unitEq;
}

- (NSUInteger)hash
{
    return [_accession hash] ^ [_ontologyRef hash];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MPGOCVParam %@:%@ \"%@\"%@%@>",
            _ontologyRef, _accession, _name,
            _value ? [NSString stringWithFormat:@" = %@", _value] : @"",
            _unit  ? [NSString stringWithFormat:@" [%@]",  _unit]  : @""];
}

@end
