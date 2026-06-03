#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"
NS_ASSUME_NONNULL_BEGIN

@interface TTIOChannelPayload : NSObject
@end

@interface TTIOBytesPayload : TTIOChannelPayload
@property (readonly, copy) NSData *bytes;
- (instancetype)initWithBytes:(NSData *)bytes;
@end

@interface TTIOGroupPayload : TTIOChannelPayload
@property (readonly, strong) id<TTIOStorageGroup> group;
- (instancetype)initWithGroup:(id<TTIOStorageGroup>)group;
@end

NS_ASSUME_NONNULL_END
