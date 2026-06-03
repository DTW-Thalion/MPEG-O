#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"
#import "Codecs/Registry/TTIOCodec.h"
NS_ASSUME_NONNULL_BEGIN

@interface TTIOCodecRegistry : NSObject
/** The codec for a wire id, or nil for unregistered/reserved ids (membership-safe). */
+ (nullable id<TTIOCodec>)codecForId:(TTIOCompression)codecId;
@end

NS_ASSUME_NONNULL_END
