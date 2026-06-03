#import "Codecs/Registry/TTIOEncodedChannel.h"

@implementation TTIOEncodedChannel
@end

@implementation TTIOEncodedDatasetBytes
- (instancetype)initWithBytes:(NSData *)bytes {
    if ((self = [super init])) { _bytes = [bytes copy]; }
    return self;
}
@end

@implementation TTIOEncodedGroupLayout
- (instancetype)initWithChildren:(NSDictionary<NSString *, NSData *> *)children
                           attrs:(NSDictionary<NSString *, id> *)attrs {
    if ((self = [super init])) { _children = [children copy]; _attrs = [attrs copy]; }
    return self;
}
@end
