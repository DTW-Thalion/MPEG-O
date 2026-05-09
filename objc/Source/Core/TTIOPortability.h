#ifndef TTIO_PORTABILITY_H
#define TTIO_PORTABILITY_H

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Cross-Foundation portability shims for code that needs to compile on
 * both Apple Foundation and GNUstep-base 1.31.1 (the version pinned by
 * GHA's apt source). Two known gaps as of 2026-05:
 *
 * 1. NSJSONWritingSortedKeys
 *    Apple declares this constant (10.13+, value 1UL<<2). GNUstep declares
 *    it only when GS_API_VERSION is opened to 10.13+ APIs (value 1UL<<1).
 *    GHA's gnustep-base 1.31.1 closes the API gate so the symbol is not
 *    declared at compile time. TTIO_JSON_SORTED_KEYS substitutes the
 *    platform-correct literal so the code compiles regardless;
 *    implementations honour the bit when present, ignore unknown option
 *    bits otherwise.
 *
 * 2. -[NSData dataWithContentsOfFile:options:error:]
 *    Apple has had this since 10.4. GNUstep-base 1.31.1 has only the
 *    older `dataWithContentsOfFile:` (no options, no error). The
 *    TTIODataWithContentsOfFileE() shim uses the simpler API everywhere
 *    and synthesises a generic NSCocoaErrorDomain/NSFileReadUnknownError
 *    when the read returns nil and the caller asked for one.
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

#endif /* TTIO_PORTABILITY_H */
