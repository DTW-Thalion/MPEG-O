#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/Registry/TTIODecodedChannel.h"
#import "Codecs/Registry/TTIOEncodedChannel.h"
#import "Codecs/Registry/TTIOChannelPayload.h"

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
    }
}
