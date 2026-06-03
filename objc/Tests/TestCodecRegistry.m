#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/Registry/TTIODecodedChannel.h"
#import "Codecs/Registry/TTIOEncodedChannel.h"
#import "Codecs/Registry/TTIOChannelPayload.h"
#import "Codecs/Registry/TTIOCodecContext.h"
#import "Codecs/Registry/TTIOCodecRegistry.h"
#import "Codecs/Registry/TTIOCodec.h"
#import "Genomics/TTIOGenomicRun.h"

void testCodecRegistry(void)
{
    @autoreleasepool {
        TTIODecodedChannel *d =
            [[TTIODecodedBytes alloc] initWithData:[NSData dataWithBytes:"abc" length:3]];
        PASS([d isKindOfClass:[TTIODecodedBytes class]],
             "TTIODecodedBytes is a TTIODecodedChannel");
        PASS([((TTIODecodedBytes *)d).data length] == 3, "decoded bytes length");

        TTIODecodedChannel *s =
            [[TTIODecodedStringList alloc] initWithNames:@[@"r1", @"r2"]];
        PASS([((TTIODecodedStringList *)s).names count] == 2, "decoded str-list");

        TTIOEncodedChannel *e =
            [[TTIOEncodedDatasetBytes alloc] initWithBytes:[NSData dataWithBytes:"x" length:1]];
        PASS([e isKindOfClass:[TTIOEncodedDatasetBytes class]], "encoded dataset-bytes");

        TTIOEncodedChannel *g =
            [[TTIOEncodedGroupLayout alloc]
                initWithChildren:@{@"refdiff_v2": [NSData data]} attrs:@{}];
        PASS([((TTIOEncodedGroupLayout *)g).children objectForKey:@"refdiff_v2"] != nil,
             "encoded group-layout child");

        TTIOChannelPayload *p =
            [[TTIOBytesPayload alloc] initWithBytes:[NSData dataWithBytes:"q" length:1]];
        PASS([((TTIOBytesPayload *)p).bytes length] == 1, "bytes payload");

        // Plain round-trip via registry (RANS0/1, BASE_PACK — lossless).
        TTIOCompression plain[3] = {TTIOCompressionRansOrder0,
                                    TTIOCompressionRansOrder1,
                                    TTIOCompressionBasePack};
        for (int k = 0; k < 3; k++) {
            id<TTIOCodec> codec = [TTIOCodecRegistry codecForId:plain[k]];
            PASS(codec != nil, "plain codec registered: %d", (int)plain[k]);
            PASS([codec codecId] == plain[k], "codecId matches");
            PASS(![codec isContextAware], "plain codec not context-aware");
            uint8_t buf[256]; for (int i = 0; i < 256; i++) buf[i] = (uint8_t)i;
            NSData *data = [NSData dataWithBytes:buf length:256];
            NSError *err = nil;
            TTIOEncodedChannel *enc =
                [codec encode:[[TTIODecodedBytes alloc] initWithData:data]
                      context:[TTIOCodecContext emptyContext] error:&err];
            NSData *encBytes = ((TTIOEncodedDatasetBytes *)enc).bytes;
            TTIODecodedChannel *dec =
                [codec decode:[[TTIOBytesPayload alloc] initWithBytes:encBytes]
                      context:[TTIOCodecContext emptyContext] error:&err];
            PASS([((TTIODecodedBytes *)dec).data isEqualToData:data],
                 "plain codec round-trip byte-identical: %d", (int)plain[k]);
        }
        // delta needs elementSize.
        id<TTIOCodec> delta = [TTIOCodecRegistry codecForId:TTIOCompressionDeltaRansOrder0];
        PASS(delta != nil, "delta registered");
        NSError *derr = nil;
        TTIOEncodedChannel *de =
            [delta encode:[[TTIODecodedBytes alloc] initWithData:[NSData dataWithBytes:"\0\0\0\0" length:4]]
                  context:[TTIOCodecContext emptyContext] error:&derr];
        PASS(de == nil && derr != nil, "delta encode without elementSize errors");

        // name_tok round-trip.
        id<TTIOCodec> nt = [TTIOCodecRegistry codecForId:TTIOCompressionNameTokenizedV2];
        PASS(nt != nil && ![nt isContextAware], "name_tok registered, not context-aware");
        NSMutableArray<NSString *> *names2 = [NSMutableArray array];
        for (int i = 0; i < 200; i++) [names2 addObject:[NSString stringWithFormat:@"read%d", i]];
        NSError *nerr = nil;
        TTIOEncodedChannel *ne =
            [nt encode:[[TTIODecodedStringList alloc] initWithNames:names2]
                context:[TTIOCodecContext emptyContext] error:&nerr];
        TTIODecodedChannel *nd =
            [nt decode:[[TTIOBytesPayload alloc] initWithBytes:((TTIOEncodedDatasetBytes *)ne).bytes]
                context:[TTIOCodecContext emptyContext] error:&nerr];
        PASS([((TTIODecodedStringList *)nd).names isEqualToArray:names2], "name_tok round-trip");

        // context-aware flags.
        PASS([[TTIOCodecRegistry codecForId:TTIOCompressionRefDiffV2] isContextAware], "refdiff context-aware");
        PASS([[TTIOCodecRegistry codecForId:TTIOCompressionFqzcompNx16Z] isContextAware], "fqzcomp context-aware");
        PASS([[TTIOCodecRegistry codecForId:TTIOCompressionMateInlineV2] isContextAware], "mate context-aware");
        PASS([[TTIOCodecRegistry codecForId:TTIOCompressionRefDiffV2] needsEmbeddedReference], "refdiff needs embed");
        PASS(![[TTIOCodecRegistry codecForId:TTIOCompressionFqzcompNx16Z] needsEmbeddedReference], "fqzcomp no embed");

        // Task 5: GenomicRun exposes a cached codec-context builder.
        PASS([TTIOGenomicRun instancesRespondToSelector:@selector(_codecContext)],
             "GenomicRun exposes -_codecContext");

        // Completeness: all 9 real codec ids registered.
        TTIOCompression all9[9] = {
            TTIOCompressionRansOrder0, TTIOCompressionRansOrder1, TTIOCompressionBasePack,
            TTIOCompressionQualityBinned, TTIOCompressionDeltaRansOrder0,
            TTIOCompressionFqzcompNx16Z, TTIOCompressionMateInlineV2,
            TTIOCompressionRefDiffV2, TTIOCompressionNameTokenizedV2};
        for (int k = 0; k < 9; k++)
            PASS([TTIOCodecRegistry codecForId:all9[k]] != nil, "registry covers id %d", (int)all9[k]);
        // Membership-safe: unregistered valid ids -> nil.
        PASS([TTIOCodecRegistry codecForId:TTIOCompressionNone] == nil, "NONE unregistered -> nil");
        PASS([TTIOCodecRegistry codecForId:TTIOCompressionZlib] == nil, "ZLIB unregistered -> nil");
    }
}
