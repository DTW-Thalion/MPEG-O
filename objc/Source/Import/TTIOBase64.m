/*
 * TTIOBase64.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOBase64
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Import/TTIOBase64.h
 *
 * Base64 encode/decode utility for mzML <binaryDataArray> payloads,
 * with optional zlib inflate/deflate. Wraps the Foundation base64
 * machinery and zlib's uncompress / compress2.
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "TTIOBase64.h"
#import <zlib.h>

@implementation TTIOBase64

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

#pragma mark - Encode (M19)

+ (NSString *)encodeData:(NSData *)data
{
    if (!data) return @"";
    return [data base64EncodedStringWithOptions:0];
}

+ (NSString *)encodeData:(NSData *)data
              zlibDeflate:(BOOL)deflateFlag
{
    if (!deflateFlag || data == nil || data.length == 0) {
        return [self encodeData:data];
    }

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (deflateInit(&strm, Z_DEFAULT_COMPRESSION) != Z_OK) {
        return nil;
    }
    strm.next_in  = (Bytef *)data.bytes;
    strm.avail_in = (uInt)data.length;

    NSMutableData *out = [NSMutableData dataWithLength:deflateBound(&strm, (uLong)data.length) + 16];
    strm.next_out  = (Bytef *)out.mutableBytes;
    strm.avail_out = (uInt)out.length;

    int ret = deflate(&strm, Z_FINISH);
    if (ret != Z_STREAM_END) {
        deflateEnd(&strm);
        return nil;
    }
    NSUInteger written = out.length - strm.avail_out;
    deflateEnd(&strm);
    [out setLength:written];
    return [out base64EncodedStringWithOptions:0];
}

@end
