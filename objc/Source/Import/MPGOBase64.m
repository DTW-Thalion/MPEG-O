/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGOBase64.h"
#import <zlib.h>

@implementation MPGOBase64

+ (NSData *)decodeString:(NSString *)base64String
{
    if (base64String == nil) return nil;
    NSData *raw = [[NSData alloc]
        initWithBase64EncodedString:base64String
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return raw;
}

+ (NSData *)decodeString:(NSString *)base64String
             zlibInflate:(BOOL)inflateFlag
{
    NSData *raw = [self decodeString:base64String];
    if (!inflateFlag || raw == nil || raw.length == 0) {
        return raw;
    }

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in  = (Bytef *)raw.bytes;
    strm.avail_in = (uInt)raw.length;

    if (inflateInit(&strm) != Z_OK) {
        return nil;
    }

    // Start with a 4x guess; grow on demand.
    NSMutableData *out = [NSMutableData dataWithLength:raw.length * 4 + 64];
    NSUInteger totalOut = 0;
    int ret = Z_OK;

    while (ret != Z_STREAM_END) {
        if (totalOut == out.length) {
            [out setLength:out.length * 2];
        }
        strm.next_out  = (Bytef *)out.mutableBytes + totalOut;
        strm.avail_out = (uInt)(out.length - totalOut);

        ret = inflate(&strm, Z_NO_FLUSH);
        totalOut = out.length - strm.avail_out;

        if (ret == Z_NEED_DICT || ret == Z_DATA_ERROR ||
            ret == Z_MEM_ERROR || ret == Z_STREAM_ERROR) {
            inflateEnd(&strm);
            return nil;
        }
        if (ret == Z_BUF_ERROR && strm.avail_in == 0) {
            // No more input but stream not ended.
            inflateEnd(&strm);
            return nil;
        }
    }

    inflateEnd(&strm);
    [out setLength:totalOut];
    return [NSData dataWithData:out];
}

@end
