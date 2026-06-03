#import "Codecs/Registry/TTIODecodedChannel.h"

@implementation TTIODecodedChannel
@end

@implementation TTIODecodedBytes
- (instancetype)initWithData:(NSData *)data {
    if ((self = [super init])) { _data = [data copy]; }
    return self;
}
@end

@implementation TTIODecodedStringList
- (instancetype)initWithNames:(NSArray<NSString *> *)names {
    if ((self = [super init])) { _names = [names copy]; }
    return self;
}
@end

@implementation TTIODecodedMateInfo
- (instancetype)initWithMateChromIds:(NSData *)mateChromIds
                       matePositions:(NSData *)matePositions
                     templateLengths:(NSData *)templateLengths {
    if ((self = [super init])) {
        _mateChromIds = [mateChromIds copy];
        _matePositions = [matePositions copy];
        _templateLengths = [templateLengths copy];
    }
    return self;
}
@end
