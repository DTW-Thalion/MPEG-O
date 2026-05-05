/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_BASE64_H
#define TTIO_BASE64_H

#import <Foundation/Foundation.h>

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOBase64.h</p>
 *
 * <p>Base64 encoding / decoding utilities for mzML
 * <code>&lt;binaryDataArray&gt;</code> content. mzML elements wrap
 * their numeric payload in base64 and optionally compress with zlib;
 * this class decodes the string, optionally inflates, and returns the
 * raw bytes as <code>NSData</code>. Encode-side helpers perform the
 * inverse for the mzML writer.</p>
 *
 * <p>Not thread-safe; callers are responsible for synchronisation.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers._base64_zlib</code> (private
 * helper)<br/>
 * Java: <code>java.util.Base64</code> (standard library; no TTIO
 * wrapper)</p>
 */
@interface TTIOBase64 : NSObject

#pragma mark - Decode

/**
 * Decodes a base64 string. Whitespace and newlines are tolerated.
 *
 * @param base64String The base64-encoded text payload.
 * @return The decoded bytes, or <code>nil</code> on malformed input.
 */
+ (NSData *)decodeString:(NSString *)base64String;

/**
 * Decodes and optionally zlib-inflates.
 *
 * @param base64String The base64-encoded text payload.
 * @param inflate      When <code>YES</code>, runs
 *                     <code>uncompress()</code> on the decoded bytes
 *                     and returns the inflated payload.
 * @return The decoded (and possibly inflated) bytes, or
 *         <code>nil</code> on malformed input or when
 *         <code>inflate</code> is <code>YES</code> but the bytes are
 *         not a valid zlib stream.
 */
+ (NSData *)decodeString:(NSString *)base64String
             zlibInflate:(BOOL)inflate;

#pragma mark - Encode

/**
 * Base64-encodes <code>data</code>.
 *
 * @param data Bytes to encode. <code>nil</code> yields
 *             <code>@""</code>.
 * @return The base64-encoded string.
 */
+ (NSString *)encodeData:(NSData *)data;

/**
 * Optionally zlib-compresses <code>data</code> before base64
 * encoding so the output matches what mzML readers expect for arrays
 * annotated with <code>MS:1000574</code> (zlib compression).
 *
 * @param data        Bytes to encode.
 * @param deflateFlag When <code>YES</code>, deflates before
 *                    encoding.
 * @return The base64-encoded (and possibly deflated) string.
 */
+ (NSString *)encodeData:(NSData *)data
              zlibDeflate:(BOOL)deflateFlag;

@end

#endif /* TTIO_BASE64_H */
