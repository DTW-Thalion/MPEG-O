#ifndef TTIO_PORTABILITY_H
#define TTIO_PORTABILITY_H

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Cross-Foundation portability shims for code that needs to compile on
 * both Apple Foundation and GNUstep-base 1.31.1 (the version pinned by
 * GHA's apt source). Three known gaps as of 2026-05:
 *
 * 1. NSJSONWritingSortedKeys
 *    Apple declares this constant (10.13+, value 1UL<<2). GNUstep declares
 *    it only when GS_API_VERSION is opened to 10.13+ APIs (value 1UL<<1).
 *    GHA's gnustep-base 1.31.1 closes the API gate so the symbol is not
 *    declared at compile time. TTIO_JSON_SORTED_KEYS substitutes the
 *    platform-correct literal so the code compiles regardless; the
 *    Apple implementation honours the bit, GNUstep-base 1.31.1 ignores
 *    it (the sort isn't actually implemented on that release).
 *
 *    For byte-form parity with Python's
 *    `json.dumps(d, sort_keys=True, separators=(",", ":"))` and Java's
 *    `TreeMap`-walk emit, callers MUST use TTIOSortedKeysJSON() instead
 *    of NSJSONSerialization + TTIO_JSON_SORTED_KEYS. The shim helper
 *    works regardless of the underlying Foundation's option support.
 *
 * 2. -[NSData dataWithContentsOfFile:options:error:]
 *    Apple has had this since 10.4. GNUstep-base 1.31.1 has only the
 *    older `dataWithContentsOfFile:` (no options, no error). The
 *    TTIODataWithContentsOfFileE() shim uses the simpler API everywhere
 *    and synthesises a generic NSCocoaErrorDomain/NSFileReadUnknownError
 *    when the read returns nil and the caller asked for one.
 *
 * 3. JSON sort-keys byte-form (added 2026-05-26 for transport-spec
 *    v0.11 cross-lang parity — TTIOSortedKeysJSON helper below).
 */

#import <Foundation/Foundation.h>

#ifdef __APPLE__
#  define TTIO_JSON_SORTED_KEYS ((NSJSONWritingOptions)(1UL << 2))
#else
#  define TTIO_JSON_SORTED_KEYS ((NSJSONWritingOptions)(1UL << 1))
#endif

static inline NSData *
TTIODataWithContentsOfFileE(NSString *path, NSError **error)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data && error && !*error) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                     code:NSFileReadUnknownError
                                 userInfo:@{NSFilePathErrorKey: path ?: @""}];
    }
    return data;
}

/** JSON-escape a string per RFC 8259 §7 (no \uXXXX for non-ASCII —
 *  emit UTF-8 verbatim; only escape mandatory `"`, `\`, and control
 *  characters U+0000..U+001F). */
static inline NSString *
_TTIOJsonEscape(NSString *s)
{
    NSUInteger len = s.length;
    NSMutableString *out = [NSMutableString stringWithCapacity:len];
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\b': [out appendString:@"\\b"];  break;
            case '\f': [out appendString:@"\\f"];  break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            default:
                if (c < 0x20) {
                    [out appendFormat:@"\\u%04x", c];
                } else {
                    [out appendFormat:@"%C", c];
                }
        }
    }
    return out;
}

/** Emit a sort-keys JSON object from a string-keyed dictionary.
 *
 *  Output is byte-equivalent to:
 *    - Python: `json.dumps(d, sort_keys=True, separators=(",", ":"))`
 *    - Java:   `new TreeMap<>(d).entrySet()` walked into a manual JSON
 *              StringBuilder (see ProvenanceRecord.parametersJson)
 *
 *  Values may be NSString or NSNumber (numeric literals emitted
 *  unquoted; booleans true/false; integers + doubles per %g format).
 *  Other value types fall back to their -description coerced to a
 *  JSON string literal.
 *
 *  Replaces `NSJSONSerialization dataWithJSONObject:options:TTIO_JSON_SORTED_KEYS`
 *  on platforms (GNUstep-base 1.31.1) where the sort option is a
 *  no-op. Use this helper anywhere byte-form matters for cross-language
 *  conformance (`attributes_json`, `parameters_json`, etc.). */
static inline NSString *
TTIOSortedKeysJSON(NSDictionary *dict)
{
    if (dict == nil || dict.count == 0) return @"{}";
    NSArray<NSString *> *keys =
        [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *out =
        [NSMutableString stringWithCapacity:dict.count * 32];
    [out appendString:@"{"];
    BOOL first = YES;
    for (NSString *key in keys) {
        if (!first) [out appendString:@","];
        first = NO;
        [out appendString:@"\""];
        [out appendString:_TTIOJsonEscape(key)];
        [out appendString:@"\":"];
        id v = dict[key];
        if ([v isKindOfClass:[NSString class]]) {
            [out appendString:@"\""];
            [out appendString:_TTIOJsonEscape((NSString *)v)];
            [out appendString:@"\""];
        } else if ([v isKindOfClass:[NSNumber class]]) {
            NSNumber *n = (NSNumber *)v;
            const char *t = n.objCType;
            if (t[0] == 'c' || t[0] == 'B') {
                [out appendString:n.boolValue ? @"true" : @"false"];
            } else if (t[0] == 'f' || t[0] == 'd') {
                [out appendFormat:@"%.17g", n.doubleValue];
            } else {
                [out appendFormat:@"%@", n];
            }
        } else if (v == [NSNull null] || v == nil) {
            [out appendString:@"null"];
        } else {
            [out appendString:@"\""];
            [out appendString:_TTIOJsonEscape([v description])];
            [out appendString:@"\""];
        }
    }
    [out appendString:@"}"];
    return out;
}

#endif /* TTIO_PORTABILITY_H */
