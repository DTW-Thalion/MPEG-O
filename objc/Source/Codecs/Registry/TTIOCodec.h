#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"
#import "Codecs/Registry/TTIOChannelPayload.h"
#import "Codecs/Registry/TTIODecodedChannel.h"
#import "Codecs/Registry/TTIOEncodedChannel.h"
#import "Codecs/Registry/TTIOCodecContext.h"
NS_ASSUME_NONNULL_BEGIN

@protocol TTIOCodec <NSObject>
- (TTIOCompression)codecId;
- (BOOL)isContextAware;
- (BOOL)needsEmbeddedReference;
- (nullable TTIODecodedChannel *)decode:(TTIOChannelPayload *)payload
                                context:(TTIOCodecContext *)ctx
                                  error:(NSError **)error;
- (nullable TTIOEncodedChannel *)encode:(TTIODecodedChannel *)value
                                context:(TTIOCodecContext *)ctx
                                  error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
