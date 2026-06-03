#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface TTIOEncodedChannel : NSObject
@end

@interface TTIOEncodedDatasetBytes : TTIOEncodedChannel
@property (readonly, copy) NSData *bytes;
- (instancetype)initWithBytes:(NSData *)bytes;
@end

@interface TTIOEncodedGroupLayout : TTIOEncodedChannel
@property (readonly, copy) NSDictionary<NSString *, NSData *> *children;
@property (readonly, copy) NSDictionary<NSString *, id> *attrs;
- (instancetype)initWithChildren:(NSDictionary<NSString *, NSData *> *)children
                           attrs:(NSDictionary<NSString *, id> *)attrs;
@end

NS_ASSUME_NONNULL_END
