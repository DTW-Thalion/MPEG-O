#import "TTIOCompoundField.h"

@implementation TTIOCompoundField

+ (instancetype)fieldWithName:(NSString *)name kind:(TTIOCompoundFieldKind)kind
{
    return [[self alloc] initWithName:name kind:kind];
}

- (instancetype)initWithName:(NSString *)name kind:(TTIOCompoundFieldKind)kind
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
    if (![other isKindOfClass:[TTIOCompoundField class]]) return NO;
    TTIOCompoundField *o = (TTIOCompoundField *)other;
    return [_name isEqualToString:o.name] && _kind == o.kind;
}

- (NSUInteger)hash { return [_name hash] ^ (NSUInteger)_kind; }

@end
