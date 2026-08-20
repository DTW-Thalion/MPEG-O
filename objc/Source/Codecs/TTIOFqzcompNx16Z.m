/*
 * TTIOFqzcompNx16Z.m — CRAM-mimic FQZCOMP_NX16 (rANS-Nx16) codec.
 *
 * Mirrors python/src/ttio/codecs/fqzcomp_nx16_z.py byte-for-byte.
 * See the header for the wire format spec.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIOFqzcompNx16Z.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── Native rANS path (libttio_rans) ──────────────────────────────────
// libttio_rans (native/) ships the CRAM 3.1 fqzcomp_qual kernel. The
// build wires it in only when present (see Source/GNUmakefile.preamble).
// We probe with __has_include so this translation unit still compiles
// when the header is absent; +backendName then returns "pure-objc".
//
// This codec is V4-only at runtime. Encode REQUIRES the native library:
// it always emits a V4 (CRAM 3.1 fqzcomp_qual) stream and errors out if
// libttio_rans is not linked — there is no pure-ObjC V1/V2 fallback.
// Decode accepts V4 streams only; legacy V1/V2/V3 streams are rejected
// with error 203 ("no longer supported in v1.0"). The old pure-ObjC
// V1/V2 rANS implementation has been removed (it was dead code).
#if __has_include("ttio_rans.h")
#  include "ttio_rans.h"
#  define TTIO_HAS_NATIVE_RANS 1
#else
#  define TTIO_HAS_NATIVE_RANS 0
#endif

NSString * const TTIOFqzcompNx16ZErrorDomain = @"TTIOFqzcompNx16ZError";

// ── Wire format constants ──────────────────────────────────────────
//
// Only the V4 path is live. The legacy V1/V2 version bytes are kept so
// +decodeData:revcompFlags:error: can reject those streams with a clear
// "no longer supported in v1.0" error (code 203).

enum {
    kZ_VERSION_V2_NATIVE      = 2,  // legacy V1/V2 — decode-rejected (203)
    kZ_VERSION_V4_FQZCOMP     = 4,  // V4 CRAM 3.1 fqzcomp port (libttio_rans)
    // V4 SAM-style flag byte (bit 4 = SAM_REVERSE; mirrors Python _SAM_REVERSE).
    kZ_V4_SAM_REVERSE         = 0x10,
    // V4 outer header minimum length: magic(4)+ver(1)+flags(1)+nQ(8)+
    // nReads(8)+rltLen(4) = 26. The Phase 2c empty-run convention emits
    // exactly 26 bytes (no body). Non-empty streams add the rlt body
    // and the 4-byte cram_body_len field + cram body.
    kZ_V4_HEADER_MIN_LEN      = 4 + 1 + 1 + 8 + 8 + 4,  // 26
};

static const uint8_t kZ_MAGIC[4] = { 'M', '9', '4', 'Z' };

// ── LE byte helpers ───────────────────────────────────────────────

static inline uint64_t le_read_u64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)p[i] << (i * 8);
    return v;
}

// ── Error helper ──────────────────────────────────────────────────

static void z_set_error(NSError * _Nullable * _Nullable outError,
                          NSInteger code,
                          NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void z_set_error(NSError * _Nullable * _Nullable outError,
                          NSInteger code,
                          NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// ── Top-level encode / decode ────────────────────────────────────

@implementation TTIOFqzcompNx16Z

+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                    error:(NSError * _Nullable *)error
{
    return [self encodeWithQualities:qualities
                          readLengths:readLengths
                         revcompFlags:revcompFlags
                              options:nil
                                error:error];
}

+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                  options:(nullable NSDictionary<NSString *, id> *)options
                                    error:(NSError * _Nullable *)error
{
    if (qualities == nil) {
        z_set_error(error, 100, @"qualities must not be nil");
        return nil;
    }
    if (readLengths.count != revcompFlags.count) {
        z_set_error(error, 101,
            @"readLengths.count (%lu) != revcompFlags.count (%lu)",
            (unsigned long)readLengths.count, (unsigned long)revcompFlags.count);
        return nil;
    }
    uint64_t total = 0;
    NSUInteger nReads = readLengths.count;
    int32_t *rls = (int32_t *)malloc(sizeof(int32_t) * (nReads ?: 1));
    int8_t  *rcs = (int8_t  *)malloc(sizeof(int8_t)  * (nReads ?: 1));
    if (!rls || !rcs) {
        free(rls); free(rcs);
        z_set_error(error, 102, @"alloc failed");
        return nil;
    }
    for (NSUInteger i = 0; i < nReads; i++) {
        uint32_t v = (uint32_t)[readLengths[i] unsignedLongLongValue];
        rls[i] = (int32_t)v;
        total += v;
        rcs[i] = ([revcompFlags[i] unsignedIntegerValue] & 1u) ? 1 : 0;
    }
    if (total != qualities.length) {
        free(rls); free(rcs);
        z_set_error(error, 103,
            @"sum(readLengths) (%llu) != qualities.length (%lu)",
            (unsigned long long)total, (unsigned long)qualities.length);
        return nil;
    }

    // The encoder always emits V4 (CRAM 3.1 fqzcomp_qual). The
    // qbits/pbits/dbits/sloc context-table parameters in `options`
    // are accepted for API compatibility but ignored on the V4 path.
#if TTIO_HAS_NATIVE_RANS
    free(rls); free(rcs);
    {
        NSInteger strategy = -1;
        id sv = options ? options[@"v4StrategyHint"] : nil;
        if ([sv isKindOfClass:[NSNumber class]]) {
            strategy = [(NSNumber *)sv integerValue];
        }
        uint8_t padCount =
            (uint8_t)((-(NSInteger)qualities.length) & 0x3);
        return [self encodeV4WithQualities:qualities
                               readLengths:readLengths
                              revcompFlags:revcompFlags
                              strategyHint:strategy
                                  padCount:padCount
                                     error:error];
    }
#else
    free(rls); free(rcs);
    z_set_error(error, 99,
        @"M94.Z encode requires libttio_rans (V4 is the only "
        @"supported encoder under v1.0); native library is not "
        @"linked.");
    return nil;
#endif
}


+ (nullable NSDictionary *)decodeData:(NSData *)data
                                 error:(NSError * _Nullable *)error
{
    return [self decodeData:data revcompFlags:nil error:error];
}

+ (nullable NSDictionary *)decodeData:(NSData *)data
                          revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                                 error:(NSError * _Nullable *)error
{
    if (data == nil) {
        z_set_error(error, 200, @"data must not be nil");
        return nil;
    }
    // Need enough bytes to read magic + version byte before dispatching.
    if (data.length < 5) {
        z_set_error(error, 201, @"M94Z: encoded too short (%lu bytes)",
                    (unsigned long)data.length);
        return nil;
    }
    const uint8_t *p = (const uint8_t *)data.bytes;
    if (memcmp(p, kZ_MAGIC, 4) != 0) {
        z_set_error(error, 202,
            @"M94Z: bad magic %02x %02x %02x %02x (expected M94Z)",
            p[0], p[1], p[2], p[3]);
        return nil;
    }
    uint8_t version = p[4];
    // Only V4 (CRAM 3.1 fqzcomp_qual) is decoded; the older flavors
    // are rejected with a clear error so legacy files surface a
    // re-encode hint.
    if (version == kZ_VERSION_V4_FQZCOMP) {
        return [self decodeV4Data:data revcompFlags:revcompFlags error:error];
    }
    if (version == 6) {
        /* V6 builds its context from qualities alone. */
        return [self decodeQualData:data revcompFlags:revcompFlags
                          sequences:nil error:error];
    }
    if (version == 5) {
        z_set_error(error, 210,
            @"M94Z V5 stream requires sequences: use "
            @"decodeData:revcompFlags:sequencesProvider:error:");
        return nil;
    }
    if (version == 1 || version == kZ_VERSION_V2_NATIVE || version == 3) {
        z_set_error(error, 203,
            @"FQZCOMP_NX16_Z V%u is no longer supported in v1.0; "
            @"only V4 (CRAM 3.1 fqzcomp_qual) is decoded. "
            @"Re-encode with v1.0+.", (unsigned)version);
        return nil;
    }
    z_set_error(error, 203, @"M94Z: unsupported version 0x%02x", version);
    return nil;
}


+ (nullable NSDictionary *)decodeData:(NSData *)data
                          revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                     sequencesProvider:(NSData * _Nullable (^_Nullable)(void))sequencesProvider
                                 error:(NSError * _Nullable *)error
{
    if (data != nil && data.length >= 5
        && ((const uint8_t *)data.bytes)[4] == 6) {
        return [self decodeQualData:data revcompFlags:revcompFlags
                          sequences:nil error:error];
    }
    if (data != nil && data.length >= 5
        && ((const uint8_t *)data.bytes)[4] == 5) {
        if (sequencesProvider == nil) {
            z_set_error(error, 210,
                @"M94Z V5 stream requires sequences: pass a "
                @"sequencesProvider returning the run's decoded "
                @"sequences bytes");
            return nil;
        }
        NSData *seq = sequencesProvider();
        if (seq == nil) {
            z_set_error(error, 211,
                @"M94Z V5: sequencesProvider returned nil");
            return nil;
        }
        return [self decodeQualData:data revcompFlags:revcompFlags
                          sequences:seq error:error];
    }
    return [self decodeData:data revcompFlags:revcompFlags error:error];
}

+ (nullable NSDictionary *)decodeQualData:(NSData *)data
                             revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                                sequences:(NSData *)sequences
                                    error:(NSError * _Nullable *)error
{
#if !TTIO_HAS_NATIVE_RANS
    z_set_error(error, 310,
        @"M94.Z decode requires libttio_rans, which is not linked");
    return nil;
#else
    if (data == nil || data.length < (NSUInteger)kZ_V4_HEADER_MIN_LEN) {
        z_set_error(error, 312, @"M94.Z V5: header truncated");
        return nil;
    }
    const uint8_t *p = (const uint8_t *)data.bytes;
    if (memcmp(p, kZ_MAGIC, 4) != 0 || (p[4] != 5 && p[4] != 6)) {
        z_set_error(error, 313, @"not an M94.Z V5 or V6 stream");
        return nil;
    }
    uint64_t numQualities = le_read_u64(p + 6);
    uint64_t numReads     = le_read_u64(p + 14);
    if (numQualities > (1ULL << 40) || numReads > (1ULL << 32)) {
        z_set_error(error, 315, @"M94.Z V5: implausible header counts");
        return nil;
    }
    if (p[4] == 5 && (uint64_t)sequences.length != numQualities) {
        z_set_error(error, 320,
            @"M94Z V5: sequences length (%lu) != num_qualities (%llu)",
            (unsigned long)sequences.length,
            (unsigned long long)numQualities);
        return nil;
    }
    NSArray<NSNumber *> *effectiveFlags = revcompFlags;
    if (effectiveFlags == nil) {
        NSMutableArray *zeros = [NSMutableArray arrayWithCapacity:(NSUInteger)numReads];
        for (uint64_t i = 0; i < numReads; i++) [zeros addObject:@0];
        effectiveFlags = zeros;
    } else if ((uint64_t)effectiveFlags.count != numReads) {
        z_set_error(error, 317,
            @"revcompFlags.count %lu != numReads %llu",
            (unsigned long)effectiveFlags.count,
            (unsigned long long)numReads);
        return nil;
    }
    uint32_t *lens  = (uint32_t *)malloc((size_t)numReads * sizeof(uint32_t));
    uint8_t  *flags = (uint8_t  *)malloc((size_t)numReads ?: 1);
    if (!lens || !flags) {
        free(lens); free(flags);
        z_set_error(error, 318, @"M94.Z V5: alloc failed");
        return nil;
    }
    for (uint64_t i = 0; i < numReads; i++) {
        flags[i] = ([effectiveFlags[(NSUInteger)i] unsignedIntegerValue] & 1u)
                     ? (uint8_t)kZ_V4_SAM_REVERSE : (uint8_t)0;
    }
    NSMutableData *outQ = [NSMutableData dataWithLength:(NSUInteger)numQualities];
    int rc = ttio_m94z_qual_decode(
        p, (size_t)data.length,
        lens, (size_t)numReads,
        flags,
        (const uint8_t *)sequences.bytes,
        (uint8_t *)outQ.mutableBytes, (size_t)numQualities);
    free(flags);
    if (rc != 0) {
        free(lens);
        z_set_error(error, 319, @"ttio_m94z_qual_decode failed (rc=%d)", rc);
        return nil;
    }
    NSMutableArray<NSNumber *> *readLengths =
        [NSMutableArray arrayWithCapacity:(NSUInteger)numReads];
    for (uint64_t i = 0; i < numReads; i++) {
        [readLengths addObject:@(lens[i])];
    }
    free(lens);
    return @{ @"qualities": outQ, @"readLengths": readLengths };
#endif
}

// ── V4 native dispatch (Stage 3, Task 7) ─────────────────────────────
//
// V4 wraps htscodecs's fqzcomp_qual (CRAM 3.1) with an M94.Z outer
// header (magic "M94Z", version=4). Both encode and decode go through
// libttio_rans; the C library handles RLT deflate/inflate, header
// packing, and the inner CRAM body. Cross-language byte-equal with
// Python (ttio.codecs.fqzcomp_nx16_z) and Java
// (global.thalion.ttio.codecs.FqzcompNx16Z).

+ (nullable NSData *)encodeQualWithQualities:(NSData *)qualities
                                 readLengths:(NSArray<NSNumber *> *)readLengths
                                revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                   sequences:(nullable NSData *)sequences
                                strategyHint:(NSInteger)strategyHint
                                    padCount:(uint8_t)padCount
                                       error:(NSError * _Nullable *)error
{
#if !TTIO_HAS_NATIVE_RANS
    z_set_error(error, 300,
        @"M94.Z V4 requires libttio_rans, which is not linked");
    return nil;
#else
    if (qualities == nil) {
        z_set_error(error, 301, @"qualities must not be nil");
        return nil;
    }
    if (sequences != nil && sequences.length != qualities.length) {
        z_set_error(error, 307,
            @"sequences length (%lu) != qualities length (%lu); the V5 "
            @"sequence context needs one base per quality",
            (unsigned long)sequences.length,
            (unsigned long)qualities.length);
        return nil;
    }
    if (readLengths.count != revcompFlags.count) {
        z_set_error(error, 302,
            @"readLengths.count (%lu) != revcompFlags.count (%lu)",
            (unsigned long)readLengths.count,
            (unsigned long)revcompFlags.count);
        return nil;
    }
    NSUInteger n_qual  = qualities.length;
    NSUInteger n_reads = readLengths.count;

    /* Empty-run short-circuit (Phase 2c reconciliation): the native V4
     * fqzcomp_qual core rejects zero-length inputs. Synthesise a
     * minimal 26-byte V4 outer header so readers can still dispatch by
     * version byte. Layout per m94z_v4_wire.h: magic(4) + version(1) +
     * flags(1) + num_qualities(8) + num_reads(8) + rlt_compressed_len(4)
     * = 26 bytes total. Cross-language convention shared with Python
     * and Java. */
    if (n_qual == 0) {
        uint8_t hdr[26];
        memset(hdr, 0, sizeof(hdr));
        hdr[0] = 'M'; hdr[1] = '9'; hdr[2] = '4'; hdr[3] = 'Z';
        hdr[4] = 4;                    /* VERSION_V4_FQZCOMP */
        hdr[5] = (uint8_t)((padCount & 0x3) << 4);
        /* num_qualities (LE uint64) at offset 6  — already zero */
        /* num_reads     (LE uint64) at offset 14 — already zero */
        /* rlt_compressed_len (LE uint32) at offset 22 — already zero */
        return [NSData dataWithBytes:hdr length:sizeof(hdr)];
    }

    /* Marshal NSArray<NSNumber*> → C buffers. */
    uint32_t *lens = NULL;
    uint8_t  *flags = NULL;
    if (n_reads) {
        lens  = (uint32_t *)malloc(n_reads * sizeof(uint32_t));
        flags = (uint8_t  *)malloc(n_reads);
        if (!lens || !flags) {
            free(lens); free(flags);
            z_set_error(error, 303, @"M94.Z V4: alloc failed");
            return nil;
        }
        uint64_t total = 0;
        for (NSUInteger i = 0; i < n_reads; i++) {
            uint32_t v = (uint32_t)[readLengths[i] unsignedLongLongValue];
            lens[i] = v;
            total += v;
            flags[i] = ([revcompFlags[i] unsignedIntegerValue] & 1u)
                         ? (uint8_t)kZ_V4_SAM_REVERSE : (uint8_t)0;
        }
        if (total != (uint64_t)n_qual) {
            free(lens); free(flags);
            z_set_error(error, 304,
                @"sum(readLengths) (%llu) != qualities.length (%lu)",
                (unsigned long long)total, (unsigned long)n_qual);
            return nil;
        }
    }

    /* Output capacity: outer header (~30) + RLT (deflated, bounded by
     * 4*n_reads) + cram body (worst case ~ qualities + slack). Match
     * Python's _encode_v4_native sizing. */
    size_t out_cap = 64 + 4 * (size_t)n_reads + (size_t)n_qual * 2 + 1024;
    uint8_t *out = (uint8_t *)malloc(out_cap);
    if (!out) {
        free(lens); free(flags);
        z_set_error(error, 305, @"M94.Z V4: out buffer alloc failed");
        return nil;
    }
    size_t out_len = out_cap;
    int rc = ttio_m94z_qual_encode(
        (const uint8_t *)qualities.bytes, (size_t)n_qual,
        lens, (size_t)n_reads,
        flags,
        (const uint8_t *)sequences.bytes,
        (int)strategyHint,
        (uint8_t)(padCount & 0x3),
        out, &out_len);
    free(lens); free(flags);
    if (rc != 0) {
        free(out);
        z_set_error(error, 306,
            @"ttio_m94z_qual_encode failed (rc=%d)", rc);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:out length:out_len freeWhenDone:YES];
#endif
}

+ (nullable NSData *)encodeV4WithQualities:(NSData *)qualities
                                readLengths:(NSArray<NSNumber *> *)readLengths
                               revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                               strategyHint:(NSInteger)strategyHint
                                   padCount:(uint8_t)padCount
                                      error:(NSError * _Nullable *)error
{
    return [self encodeQualWithQualities:qualities
                             readLengths:readLengths
                            revcompFlags:revcompFlags
                               sequences:nil
                            strategyHint:strategyHint
                                padCount:padCount
                                   error:error];
}

+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                sequences:(nullable NSData *)sequences
                                    error:(NSError * _Nullable *)error
{
    uint8_t padCount = (uint8_t)((-(NSInteger)qualities.length) & 0x3);
    return [self encodeQualWithQualities:qualities
                             readLengths:readLengths
                            revcompFlags:revcompFlags
                               sequences:sequences
                            strategyHint:-1
                                padCount:padCount
                                   error:error];
}

+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                sequences:(nullable NSData *)sequences
                             strategyHint:(NSInteger)strategyHint
                                    error:(NSError * _Nullable *)error
{
    uint8_t padCount = (uint8_t)((-(NSInteger)qualities.length) & 0x3);
    return [self encodeQualWithQualities:qualities
                             readLengths:readLengths
                            revcompFlags:revcompFlags
                               sequences:sequences
                            strategyHint:strategyHint
                                padCount:padCount
                                   error:error];
}

+ (nullable NSDictionary *)decodeV4Data:(NSData *)data
                             revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                                    error:(NSError * _Nullable *)error
{
#if !TTIO_HAS_NATIVE_RANS
    z_set_error(error, 310,
        @"M94.Z V4 decode requires libttio_rans, which is not linked");
    return nil;
#else
    if (data == nil) {
        z_set_error(error, 311, @"data must not be nil");
        return nil;
    }
    if (data.length < (NSUInteger)kZ_V4_HEADER_MIN_LEN) {
        z_set_error(error, 312,
            @"M94.Z V4: header truncated (%lu < %d)",
            (unsigned long)data.length, kZ_V4_HEADER_MIN_LEN);
        return nil;
    }
    const uint8_t *p = (const uint8_t *)data.bytes;
    if (memcmp(p, kZ_MAGIC, 4) != 0) {
        z_set_error(error, 313,
            @"M94.Z V4: bad magic %02x %02x %02x %02x",
            p[0], p[1], p[2], p[3]);
        return nil;
    }
    if (p[4] != (uint8_t)kZ_VERSION_V4_FQZCOMP) {
        z_set_error(error, 314,
            @"M94.Z V4: expected version %d, got %d",
            kZ_VERSION_V4_FQZCOMP, (int)p[4]);
        return nil;
    }
    /* p[5] = flags (bits 4-5 = pad_count) — informational only. */
    uint64_t numQualities = le_read_u64(p + 6);
    uint64_t numReads     = le_read_u64(p + 14);

    if (numQualities > (1ULL << 40)) {
        z_set_error(error, 315,
            @"M94.Z V4: implausible num_qualities %llu",
            (unsigned long long)numQualities);
        return nil;
    }
    if (numReads > (1ULL << 32)) {
        z_set_error(error, 316,
            @"M94.Z V4: implausible num_reads %llu",
            (unsigned long long)numReads);
        return nil;
    }

    /* Empty-run short-circuit (Phase 2c reconciliation): the 26-byte
     * minimal V4 header carries no body. Return empty result without
     * dispatching to the native fqzcomp_qual core (which rejects
     * zero-length inputs). Cross-language convention shared with
     * Python and Java. */
    if (numQualities == 0 && numReads == 0) {
        return @{
            @"qualities":   [NSData data],
            @"readLengths": @[],
        };
    }

    NSArray<NSNumber *> *effectiveFlags = revcompFlags;
    if (effectiveFlags == nil) {
        NSMutableArray *zeros = [NSMutableArray arrayWithCapacity:(NSUInteger)numReads];
        for (uint64_t i = 0; i < numReads; i++) [zeros addObject:@0];
        effectiveFlags = zeros;
    } else if ((uint64_t)effectiveFlags.count != numReads) {
        z_set_error(error, 317,
            @"revcompFlags.count %lu != numReads %llu",
            (unsigned long)effectiveFlags.count,
            (unsigned long long)numReads);
        return nil;
    }

    uint32_t *lens  = NULL;
    uint8_t  *flags = NULL;
    if (numReads) {
        lens  = (uint32_t *)malloc((size_t)numReads * sizeof(uint32_t));
        flags = (uint8_t  *)malloc((size_t)numReads);
        if (!lens || !flags) {
            free(lens); free(flags);
            z_set_error(error, 318, @"M94.Z V4: alloc failed");
            return nil;
        }
        for (uint64_t i = 0; i < numReads; i++) {
            flags[i] = ([effectiveFlags[(NSUInteger)i] unsignedIntegerValue] & 1u)
                         ? (uint8_t)kZ_V4_SAM_REVERSE : (uint8_t)0;
        }
    }

    NSMutableData *outQ = [NSMutableData dataWithLength:(NSUInteger)numQualities];
    int rc = ttio_m94z_v4_decode(
        p, (size_t)data.length,
        lens, (size_t)numReads,
        flags,
        (uint8_t *)outQ.mutableBytes, (size_t)numQualities);
    free(flags);
    if (rc != 0) {
        free(lens);
        z_set_error(error, 319, @"ttio_m94z_v4_decode failed (rc=%d)", rc);
        return nil;
    }

    NSMutableArray<NSNumber *> *readLengths =
        [NSMutableArray arrayWithCapacity:(NSUInteger)numReads];
    for (uint64_t i = 0; i < numReads; i++) {
        [readLengths addObject:@(lens[i])];
    }
    free(lens);

    return @{
        @"qualities":   outQ,
        @"readLengths": readLengths,
    };
#endif
}

// ── Backend introspection (Task 17, Phase B) ─────────────────────────
// Mirrors Python's get_backend_name() and Java's FqzcompNx16Z.getBackendName().
// Returns "native-<kernel>" when libttio_rans is linked (the only build
// in which encode/decode work), else "pure-objc" (encode/decode error).

+ (NSString *)engineName
{
#if TTIO_HAS_NATIVE_RANS
    const char *n = ttio_engine_active_name();
    return (n != NULL && n[0] != '\0') ? [NSString stringWithUTF8String:n]
                                       : @"cpu";
#else
    return @"cpu";
#endif
}

+ (BOOL)gpuAvailable
{
#if TTIO_HAS_NATIVE_RANS
    return ttio_engine_gpu_available() != 0;
#else
    return NO;
#endif
}

+ (NSInteger)strategyOfEncodedStream:(NSData *)stream
{
#if TTIO_HAS_NATIVE_RANS
    return (NSInteger)ttio_m94z_qual_stream_strategy(
        (const uint8_t *)stream.bytes, (size_t)stream.length);
#else
    /* Wire-layout mirror of ttio_m94z_qual_stream_strategy
     * (m94z_v4_wire.c) for builds without libttio_rans. */
    const uint8_t *in = (const uint8_t *)stream.bytes;
    size_t in_len = (size_t)stream.length;
    if (in == NULL || in_len < 30) return -1;
    if (memcmp(in, "M94Z", 4) != 0) return -2;
    if (in[4] == 4) return 4;
    if (in[4] == 6) {
        uint32_t v6_rlt;
        memcpy(&v6_rlt, in + 22, 4);
        if (in_len < (size_t)30 + v6_rlt + 1) return -3;
        return 8;
    }
    if (in[4] != 5) return -2;
    uint32_t rlt_len;
    memcpy(&rlt_len, in + 22, 4);
    if (in_len < (size_t)30 + rlt_len + 2) return -3;
    uint8_t sid = in[30 + (size_t)rlt_len + 1];
    return (sid == 5 || sid == 6) ? (NSInteger)sid : -3;
#endif
}

+ (NSString *)backendName
{
#if TTIO_HAS_NATIVE_RANS
    const char *kernel = ttio_rans_kernel_name();
    if (kernel == NULL || kernel[0] == '\0') {
        return @"native-unknown";
    }
    return [NSString stringWithFormat:@"native-%s", kernel];
#else
    return @"pure-objc";
#endif
}

@end
