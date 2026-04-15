/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef MPGO_BASE64_H
#define MPGO_BASE64_H

#import <Foundation/Foundation.h>

/**
 * Base64 decoding utilities for mzML binaryDataArray content.
 *
 * mzML <binaryDataArray> elements wrap their numeric payload in base64
 * and optionally compress with zlib. This class decodes the string,
 * optionally inflates, and returns the raw bytes as NSData.
 *
 * Not thread-safe; callers are responsible for synchronization.
 */
@interface MPGOBase64 : NSObject

/** Decode a base64 string. Whitespace and newlines are tolerated.
 *  Returns nil on malformed input. */
+ (NSData *)decodeString:(NSString *)base64String;

/** Decode and optionally zlib-inflate. If inflate is NO, behaves like
 *  -decodeString:. If YES, runs uncompress() on the decoded bytes;
 *  returns nil if the output is not a valid zlib stream. */
+ (NSData *)decodeString:(NSString *)base64String
             zlibInflate:(BOOL)inflate;

@end

#endif /* MPGO_BASE64_H */
