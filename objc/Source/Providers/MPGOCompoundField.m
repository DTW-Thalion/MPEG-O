#import "MPGOCompoundField.h"

@implementation MPGOCompoundField

+ (instancetype)fieldWithName:(NSString *)name kind:(MPGOCompoundFieldKind)kind
{
    return [[self alloc] initWithName:name kind:kind];
}

- (instancetype)initWithName:(NSString *)name kind:(MPGOCompoundFieldKind)kind
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _kind = kind;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOCompoundField class]]) return NO;
    MPGOCompoundField *o = (MPGOCompoundField *)other;
    return [_name isEqualToString:o.name] && _kind == o.kind;
}

- (NSUInteger)hash { return [_name hash] ^ (NSUInteger)_kind; }

@end
