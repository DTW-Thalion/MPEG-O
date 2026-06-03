#import "Codecs/Registry/TTIOCodecRegistry.h"
#import "Codecs/TTIORans.h"
#import "Codecs/TTIOBasePack.h"
#import "Codecs/TTIOQuality.h"
#import "Codecs/TTIODeltaRans.h"
#import "Codecs/Registry/TTIOChannelPayload.h"
#import "Codecs/Registry/TTIODecodedChannel.h"
#import "Codecs/Registry/TTIOEncodedChannel.h"
#import "Codecs/Registry/TTIOCodecContext.h"
#import <pthread.h>

static NSDictionary<NSNumber *, id<TTIOCodec>> *gRegistry = nil;
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

@interface _TTIORansCodec : NSObject <TTIOCodec>
- (instancetype)initWithId:(TTIOCompression)cid order:(int)order;
@end
@implementation _TTIORansCodec {
    TTIOCompression _cid; int _order;
}
- (instancetype)initWithId:(TTIOCompression)cid order:(int)order {
    if ((self = [super init])) { _cid = cid; _order = order; }
    return self;
}
- (TTIOCompression)codecId { return _cid; }
- (BOOL)isContextAware { return NO; }
- (BOOL)needsEmbeddedReference { return NO; }
- (TTIODecodedChannel *)decode:(TTIOChannelPayload *)p context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIORansDecode(((TTIOBytesPayload *)p).bytes, e);
    return out ? [[TTIODecodedBytes alloc] initWithData:out] : nil;
}
- (TTIOEncodedChannel *)encode:(TTIODecodedChannel *)v context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIORansEncode(((TTIODecodedBytes *)v).data, _order);
    return [[TTIOEncodedDatasetBytes alloc] initWithBytes:out];
}
@end

@interface _TTIOBasePackCodec : NSObject <TTIOCodec> @end
@implementation _TTIOBasePackCodec
- (TTIOCompression)codecId { return TTIOCompressionBasePack; }
- (BOOL)isContextAware { return NO; }
- (BOOL)needsEmbeddedReference { return NO; }
- (TTIODecodedChannel *)decode:(TTIOChannelPayload *)p context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIOBasePackDecode(((TTIOBytesPayload *)p).bytes, e);
    return out ? [[TTIODecodedBytes alloc] initWithData:out] : nil;
}
- (TTIOEncodedChannel *)encode:(TTIODecodedChannel *)v context:(TTIOCodecContext *)ctx error:(NSError **)e {
    return [[TTIOEncodedDatasetBytes alloc] initWithBytes:TTIOBasePackEncode(((TTIODecodedBytes *)v).data)];
}
@end

@interface _TTIOQualityCodec : NSObject <TTIOCodec> @end
@implementation _TTIOQualityCodec
- (TTIOCompression)codecId { return TTIOCompressionQualityBinned; }
- (BOOL)isContextAware { return NO; }
- (BOOL)needsEmbeddedReference { return NO; }
- (TTIODecodedChannel *)decode:(TTIOChannelPayload *)p context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIOQualityDecode(((TTIOBytesPayload *)p).bytes, e);
    return out ? [[TTIODecodedBytes alloc] initWithData:out] : nil;
}
- (TTIOEncodedChannel *)encode:(TTIODecodedChannel *)v context:(TTIOCodecContext *)ctx error:(NSError **)e {
    return [[TTIOEncodedDatasetBytes alloc] initWithBytes:TTIOQualityEncode(((TTIODecodedBytes *)v).data)];
}
@end

@interface _TTIODeltaRansCodec : NSObject <TTIOCodec> @end
@implementation _TTIODeltaRansCodec
- (TTIOCompression)codecId { return TTIOCompressionDeltaRansOrder0; }
- (BOOL)isContextAware { return NO; }
- (BOOL)needsEmbeddedReference { return NO; }
- (TTIODecodedChannel *)decode:(TTIOChannelPayload *)p context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIODeltaRansDecode(((TTIOBytesPayload *)p).bytes, e);
    return out ? [[TTIODecodedBytes alloc] initWithData:out] : nil;
}
- (TTIOEncodedChannel *)encode:(TTIODecodedChannel *)v context:(TTIOCodecContext *)ctx error:(NSError **)e {
    if (ctx.elementSize == nil) {
        if (e) *e = [NSError errorWithDomain:@"global.thalion.ttio.CodecRegistry" code:-1
            userInfo:@{NSLocalizedDescriptionKey: @"DELTA_RANS encode requires context.elementSize"}];
        return nil;
    }
    NSData *out = TTIODeltaRansEncode(((TTIODecodedBytes *)v).data,
        (uint8_t)ctx.elementSize.unsignedCharValue, e);
    return out ? [[TTIOEncodedDatasetBytes alloc] initWithBytes:out] : nil;
}
@end

static void _buildRegistry(void) {
    gRegistry = @{
        @(TTIOCompressionRansOrder0): [[_TTIORansCodec alloc] initWithId:TTIOCompressionRansOrder0 order:0],
        @(TTIOCompressionRansOrder1): [[_TTIORansCodec alloc] initWithId:TTIOCompressionRansOrder1 order:1],
        @(TTIOCompressionBasePack):   [[_TTIOBasePackCodec alloc] init],
        @(TTIOCompressionQualityBinned): [[_TTIOQualityCodec alloc] init],
        @(TTIOCompressionDeltaRansOrder0): [[_TTIODeltaRansCodec alloc] init],
    };
}

@implementation TTIOCodecRegistry
+ (nullable id<TTIOCodec>)codecForId:(TTIOCompression)codecId {
    pthread_once(&gOnce, _buildRegistry);
    return gRegistry[@(codecId)];
}
@end
