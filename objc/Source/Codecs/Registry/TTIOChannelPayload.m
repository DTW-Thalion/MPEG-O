#import "Codecs/Registry/TTIOChannelPayload.h"

@implementation TTIOChannelPayload
@end

@implementation TTIOBytesPayload
- (instancetype)initWithBytes:(NSData *)bytes {
    if ((self = [super init])) { _bytes = [bytes copy]; }
    return self;
}
@end

@implementation TTIOGroupPayload
- (instancetype)initWithGroup:(id<TTIOStorageGroup>)group {
    if ((self = [super init])) { _group = group; }
    return self;
}
@end
