/*
 * TTIONameTokenizerV2.m -- column-aware tokenised read-name codec (codec id 15).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIONameTokenizerV2.h"

#if __has_include(<ttio_rans.h>)
#include <ttio_rans.h>
#define TTIO_HAS_NATIVE_RANS 1
#else
#define TTIO_HAS_NATIVE_RANS 0
#endif

#import <stdlib.h>
#import <string.h>

NSString *const TTIONameTokenizerV2ErrorDomain = @"global.thalion.ttio.NameTokenizerV2";

@implementation TTIONameTokenizerV2

+ (BOOL)nativeAvailable {
    return TTIO_HAS_NATIVE_RANS ? YES : NO;
}

+ (NSData *)encodeNames:(NSArray<NSString *> *)names {
#if !TTIO_HAS_NATIVE_RANS
    [NSException raise:NSInternalInconsistencyException
                format:@"libttio_rans not linked"];
    return nil;
#else
    NSUInteger n = [names count];
    NSUInteger alloc_n = n > 0 ? n : 1;
    const char **c_names = (const char **)malloc(sizeof(char *) * alloc_n);
    NSMutableArray *holders = [NSMutableArray arrayWithCapacity:n];
    NSUInteger total_bytes = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSString *s = names[i];
        const char *cs = [s cStringUsingEncoding:NSASCIIStringEncoding];
        if (cs == NULL) {
            free(c_names);
            [NSException raise:NSInvalidArgumentException
                        format:@"non-ASCII name at index %lu", (unsigned long)i];
        }
        size_t L = strlen(cs);
        char *copy = (char *)malloc(L + 1);
        memcpy(copy, cs, L + 1);
        c_names[i] = copy;
        total_bytes += L;
        [holders addObject:[NSValue valueWithPointer:copy]];
    }
    size_t cap = ttio_name_tok_v2_max_encoded_size((uint64_t)n, (uint64_t)total_bytes);
    uint8_t *out = (uint8_t *)malloc(cap);
    size_t out_len = cap;
    int rc = ttio_name_tok_v2_encode(c_names, (uint64_t)n, out, &out_len);
    for (NSValue *v in holders) free([v pointerValue]);
    free(c_names);
    if (rc != 0) {
        free(out);
        [NSException raise:NSInvalidArgumentException
                    format:@"name_tok_v2 encode rc=%d", rc];
    }
    NSData *result = [NSData dataWithBytes:out length:out_len];
    free(out);
    return result;
#endif
}

+ (nullable NSArray<NSString *> *)decodeData:(NSData *)blob
                                        error:(NSError **)error {
#if !TTIO_HAS_NATIVE_RANS
    if (error) {
        *error = [NSError errorWithDomain:TTIONameTokenizerV2ErrorDomain
                                     code:-100
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            @"libttio_rans not linked"}];
    }
    return nil;
#else
    char **out_names = NULL;
    uint64_t out_n = 0;
    int rc = ttio_name_tok_v2_decode((const uint8_t *)[blob bytes],
                                      [blob length],
                                      &out_names, &out_n);
    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:TTIONameTokenizerV2ErrorDomain
                                         code:rc
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"decode rc=%d", rc]}];
        }
        return nil;
    }
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)out_n];
    for (uint64_t i = 0; i < out_n; i++) {
        NSString *s = [NSString stringWithCString:out_names[i]
                                          encoding:NSASCIIStringEncoding];
        [result addObject:s ?: @""];
        free(out_names[i]);
    }
    free(out_names);
    return result;
#endif
}

+ (NSString *)backendName {
    return TTIO_HAS_NATIVE_RANS ? @"native" : @"none";
}

@end
