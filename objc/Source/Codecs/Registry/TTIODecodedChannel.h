#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/** Closed union of a decoded channel value: bytes | str-list | mate-info.
 *  Consumed via isKindOfClass:. Mirrors the Python/Java DecodedChannel. */
@interface TTIODecodedChannel : NSObject
@end

@interface TTIODecodedBytes : TTIODecodedChannel
@property (readonly, copy) NSData *data;
- (instancetype)initWithData:(NSData *)data;
@end

@interface TTIODecodedStringList : TTIODecodedChannel
@property (readonly, copy) NSArray<NSString *> *names;
- (instancetype)initWithNames:(NSArray<NSString *> *)names;
@end

@interface TTIODecodedMateInfo : TTIODecodedChannel
@property (readonly, copy) NSData *mateChromIds;
@property (readonly, copy) NSData *matePositions;
@property (readonly, copy) NSData *templateLengths;
- (instancetype)initWithMateChromIds:(NSData *)mateChromIds
                       matePositions:(NSData *)matePositions
                     templateLengths:(NSData *)templateLengths;
@end

NS_ASSUME_NONNULL_END
