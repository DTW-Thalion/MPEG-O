/*
 * TTIORefDiff.m — clean-room REF_DIFF reference-based sequence-diff codec.
 *
 * Mirrors python/src/ttio/codecs/ref_diff.py byte-for-byte. See the
 * header for the wire format.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIORefDiff.h"
#import "Codecs/TTIORans.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Little-endian helpers — REF_DIFF wire format is non-negotiable LE.
// On x86/ARM (the only platforms the CI matrix covers) the explicit
// byte-by-byte writers are still the safest portable approach because
// host alignment for misaligned struct-style stores is undefined; the
// per-byte form is identical in cost and works on big-endian hosts too.

NSString * const TTIORefDiffErrorDomain = @"TTIORefDiffError";

static const uint8_t kRefDiffMagic[4] = { 'R', 'D', 'I', 'F' };
static const uint8_t kRefDiffVersion  = 0x01;

enum {
    kRefDiffHeaderFixedSize     = 38,
    kRefDiffSliceIndexEntrySize = 32,
    kRefDiffSliceSizeDefault    = 10000,
};

static inline void le_pack_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)( v        & 0xFF);
    p[1] = (uint8_t)((v >> 8)  & 0xFF);
}
static inline void le_pack_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)( v        & 0xFF);
    p[1] = (uint8_t)((v >> 8)  & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}
static inline void le_pack_u64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)((v >> (i * 8)) & 0xFF);
}
static inline uint16_t le_read_u16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static inline uint32_t le_read_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline uint64_t le_read_u64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)p[i] << (i * 8);
    return v;
}

// ── Error helper ───────────────────────────────────────────────────

static void rd_set_error(NSError * _Nullable * _Nullable outError,
                         NSInteger code,
                         NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void rd_set_error(NSError * _Nullable * _Nullable outError,
                         NSInteger code,
                         NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:TTIORefDiffErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// ── Codec header ───────────────────────────────────────────────────

@implementation TTIORefDiffCodecHeader

- (instancetype)initWithNumSlices:(uint32_t)numSlices
                       totalReads:(uint64_t)totalReads
                     referenceMD5:(NSData *)referenceMD5
                     referenceURI:(NSString *)referenceURI
{
    self = [super init];
    if (self) {
        if (referenceMD5.length != 16) {
            [NSException raise:NSInvalidArgumentException
                        format:@"TTIORefDiffCodecHeader: reference_md5 must "
                                @"be 16 bytes, got %lu",
                                (unsigned long)referenceMD5.length];
        }
        NSData *uriBytes = [referenceURI dataUsingEncoding:NSUTF8StringEncoding];
        if (uriBytes.length > 0xFFFF) {
            [NSException raise:NSInvalidArgumentException
                        format:@"TTIORefDiffCodecHeader: reference_uri too "
                                @"long (%lu UTF-8 bytes > 65535)",
                                (unsigned long)uriBytes.length];
        }
        _numSlices    = numSlices;
        _totalReads   = totalReads;
        _referenceMD5 = [referenceMD5 copy];
        _referenceURI = [referenceURI copy];
    }
    return self;
}

- (NSData *)packedData
{
    NSData *uriBytes = [_referenceURI dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger total = kRefDiffHeaderFixedSize + uriBytes.length;
    NSMutableData *out = [NSMutableData dataWithLength:total];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    memcpy(p, kRefDiffMagic, 4);
    p[4] = kRefDiffVersion;
    p[5] = 0; p[6] = 0; p[7] = 0;             // reserved
    le_pack_u32(p + 8,  _numSlices);
    le_pack_u64(p + 12, _totalReads);
    memcpy(p + 20, _referenceMD5.bytes, 16);
    le_pack_u16(p + 36, (uint16_t)uriBytes.length);
    memcpy(p + 38, uriBytes.bytes, uriBytes.length);
    return out;
}

+ (nullable instancetype)headerFromData:(NSData *)blob
                          bytesConsumed:(NSUInteger *)outConsumed
                                   error:(NSError * _Nullable *)error
{
    if (blob.length < kRefDiffHeaderFixedSize) {
        rd_set_error(error, 1, @"REF_DIFF header too short: %lu < %d bytes",
                     (unsigned long)blob.length, kRefDiffHeaderFixedSize);
        return nil;
    }
    const uint8_t *p = (const uint8_t *)blob.bytes;
    if (memcmp(p, kRefDiffMagic, 4) != 0) {
        rd_set_error(error, 2, @"REF_DIFF bad magic: 0x%02x%02x%02x%02x",
                     p[0], p[1], p[2], p[3]);
        return nil;
    }
    if (p[4] != kRefDiffVersion) {
        rd_set_error(error, 3, @"REF_DIFF unsupported version: %u (expected %u)",
                     (unsigned)p[4], (unsigned)kRefDiffVersion);
        return nil;
    }
    uint32_t numSlices  = le_read_u32(p + 8);
    uint64_t totalReads = le_read_u64(p + 12);
    NSData *md5 = [NSData dataWithBytes:p + 20 length:16];
    uint16_t uriLen = le_read_u16(p + 36);
    NSUInteger end = (NSUInteger)kRefDiffHeaderFixedSize + (NSUInteger)uriLen;
    if (blob.length < end) {
        rd_set_error(error, 4, @"REF_DIFF header truncated in reference_uri "
                     @"(declared %u bytes, only %lu remain)",
                     (unsigned)uriLen,
                     (unsigned long)(blob.length - kRefDiffHeaderFixedSize));
        return nil;
    }
    NSString *uri = [[NSString alloc]
        initWithBytes:p + kRefDiffHeaderFixedSize
               length:uriLen
             encoding:NSUTF8StringEncoding];
    if (!uri) {
        rd_set_error(error, 5, @"REF_DIFF reference_uri is not valid UTF-8");
        return nil;
    }
    if (outConsumed) *outConsumed = end;
    return [[TTIORefDiffCodecHeader alloc]
        initWithNumSlices:numSlices
                totalReads:totalReads
              referenceMD5:md5
              referenceURI:uri];
}

@end

// ── Slice index entry ──────────────────────────────────────────────

typedef struct {
    uint64_t body_offset;
    uint32_t body_length;
    int64_t  first_position;
    int64_t  last_position;
    uint32_t num_reads;
} rd_slice_entry_t;

static void pack_slice_entry(uint8_t *out, const rd_slice_entry_t *e)
{
    le_pack_u64(out + 0,  e->body_offset);
    le_pack_u32(out + 8,  e->body_length);
    le_pack_u64(out + 12, (uint64_t)e->first_position);
    le_pack_u64(out + 20, (uint64_t)e->last_position);
    le_pack_u32(out + 28, e->num_reads);
}

static void unpack_slice_entry(const uint8_t *in, rd_slice_entry_t *e)
{
    e->body_offset    = le_read_u64(in + 0);
    e->body_length    = le_read_u32(in + 8);
    e->first_position = (int64_t)le_read_u64(in + 12);
    e->last_position  = (int64_t)le_read_u64(in + 20);
    e->num_reads      = le_read_u32(in + 28);
}

// ── CIGAR walker ───────────────────────────────────────────────────
//
// Result of walking one read. Held as plain bytes for speed; the
// flag bits are stored one-per-byte (0/1) so the bit-packer can read
// them sequentially without re-parsing.

typedef struct {
    uint8_t  *flag_bits;     // length: m_op_count, each value 0 or 1
    size_t    flag_count;
    uint8_t  *sub_bytes;
    size_t    sub_count;
    uint8_t  *ins_bytes;
    size_t    ins_count;
    uint8_t  *soft_bytes;
    size_t    soft_count;
} rd_walk_t;

static void rd_walk_init(rd_walk_t *w)
{
    memset(w, 0, sizeof(*w));
}

static void rd_walk_free(rd_walk_t *w)
{
    free(w->flag_bits);
    free(w->sub_bytes);
    free(w->ins_bytes);
    free(w->soft_bytes);
    memset(w, 0, sizeof(*w));
}

// Parse one CIGAR op starting at *cur. On success advances *cur past the
// op letter, writes the run length to *outLen and the op letter to *outOp,
// and returns YES. On end-of-string returns NO with *outOp set to 0; on
// malformed input returns NO with *outOp set to 0xFF.
static BOOL rd_cigar_next(const char *cig, size_t cig_len,
                          size_t *cur, uint32_t *outLen, char *outOp)
{
    if (*cur >= cig_len) { *outOp = 0; return NO; }
    uint64_t v = 0;
    BOOL sawDigit = NO;
    while (*cur < cig_len && cig[*cur] >= '0' && cig[*cur] <= '9') {
        v = v * 10 + (uint32_t)(cig[*cur] - '0');
        if (v > 0xFFFFFFFFULL) { *outOp = (char)0xFF; return NO; }
        (*cur)++;
        sawDigit = YES;
    }
    if (!sawDigit || *cur >= cig_len) { *outOp = (char)0xFF; return NO; }
    char op = cig[*cur];
    (*cur)++;
    *outLen = (uint32_t)v;
    *outOp = op;
    return YES;
}

// Returns YES on success; on bad CIGAR sets *error and returns NO.
static BOOL rd_walk_read(const uint8_t *seq, size_t seq_len,
                          const char *cig, size_t cig_len,
                          int64_t position,
                          const uint8_t *ref, size_t ref_len,
                          rd_walk_t *out,
                          NSError **error)
{
    rd_walk_init(out);
    if (cig_len == 0 || (cig_len == 1 && cig[0] == '*')) {
        rd_set_error(error, 100,
            @"REF_DIFF cannot encode unmapped reads (cigar='*' or empty); "
            @"route through BASE_PACK on a separate sub-channel");
        return NO;
    }

    // Pass 1: size everything so we can allocate exact buffers.
    size_t m_count = 0, ins_total = 0, soft_total = 0;
    {
        size_t cur = 0;
        uint32_t L; char op;
        while (rd_cigar_next(cig, cig_len, &cur, &L, &op)) {
            switch (op) {
                case 'M': case '=': case 'X': m_count    += L; break;
                case 'I':                     ins_total  += L; break;
                case 'S':                     soft_total += L; break;
                case 'D': case 'N':           /* ref-only */    break;
                case 'H': case 'P':                              break;
                default:
                    rd_set_error(error, 101,
                        @"REF_DIFF unsupported CIGAR op: %c", op);
                    return NO;
            }
        }
        if (op == (char)0xFF) {
            rd_set_error(error, 102, @"REF_DIFF malformed CIGAR string");
            return NO;
        }
    }

    out->flag_bits  = (uint8_t *)calloc(m_count   ? m_count   : 1, 1);
    // sub bytes is up to m_count; allocate worst-case.
    out->sub_bytes  = (uint8_t *)malloc(m_count    ? m_count    : 1);
    out->ins_bytes  = (uint8_t *)malloc(ins_total  ? ins_total  : 1);
    out->soft_bytes = (uint8_t *)malloc(soft_total ? soft_total : 1);

    size_t seq_i = 0;
    int64_t ref_i = position - 1;  // 1-based -> 0-based

    size_t cur = 0;
    uint32_t L; char op;
    while (rd_cigar_next(cig, cig_len, &cur, &L, &op)) {
        switch (op) {
            case 'M': case '=': case 'X':
                if (seq_i + L > seq_len || ref_i < 0 ||
                    (size_t)(ref_i + L) > ref_len) {
                    rd_set_error(error, 103,
                        @"REF_DIFF M-op out of bounds: seq_i=%zu+%u/%zu, "
                        @"ref_i=%lld+%u/%zu",
                        seq_i, L, seq_len, (long long)ref_i, L, ref_len);
                    rd_walk_free(out);
                    return NO;
                }
                for (uint32_t k = 0; k < L; k++) {
                    uint8_t rb = seq[seq_i + k];
                    uint8_t fb = ref[(size_t)ref_i + k];
                    if (rb == fb) {
                        out->flag_bits[out->flag_count++] = 0;
                    } else {
                        out->flag_bits[out->flag_count++] = 1;
                        out->sub_bytes[out->sub_count++]  = rb;
                    }
                }
                seq_i += L;
                ref_i += L;
                break;
            case 'I':
                if (seq_i + L > seq_len) {
                    rd_set_error(error, 104,
                        @"REF_DIFF I-op out of bounds: seq_i=%zu+%u/%zu",
                        seq_i, L, seq_len);
                    rd_walk_free(out);
                    return NO;
                }
                memcpy(out->ins_bytes + out->ins_count, seq + seq_i, L);
                out->ins_count += L;
                seq_i += L;
                break;
            case 'S':
                if (seq_i + L > seq_len) {
                    rd_set_error(error, 105,
                        @"REF_DIFF S-op out of bounds: seq_i=%zu+%u/%zu",
                        seq_i, L, seq_len);
                    rd_walk_free(out);
                    return NO;
                }
                memcpy(out->soft_bytes + out->soft_count, seq + seq_i, L);
                out->soft_count += L;
                seq_i += L;
                break;
            case 'D': case 'N':
                ref_i += L;
                break;
            case 'H': case 'P':
                break;
            default:
                rd_set_error(error, 106, @"REF_DIFF unsupported CIGAR op: %c", op);
                rd_walk_free(out);
                return NO;
        }
    }
    return YES;
}

// CIGAR M/I/S totals — used by the decoder to know the bit/byte budget
// per read.
static BOOL rd_cigar_totals(const char *cig, size_t cig_len,
                             size_t *m_count, size_t *ins_total, size_t *soft_total,
                             NSError **error)
{
    *m_count = 0; *ins_total = 0; *soft_total = 0;
    if (cig_len == 0 || (cig_len == 1 && cig[0] == '*')) {
        rd_set_error(error, 110, @"REF_DIFF cannot decode unmapped read");
        return NO;
    }
    size_t cur = 0;
    uint32_t L; char op;
    while (rd_cigar_next(cig, cig_len, &cur, &L, &op)) {
        switch (op) {
            case 'M': case '=': case 'X': *m_count    += L; break;
            case 'I':                     *ins_total  += L; break;
            case 'S':                     *soft_total += L; break;
            case 'D': case 'N':                              break;
            case 'H': case 'P':                              break;
            default:
                rd_set_error(error, 111,
                    @"REF_DIFF unsupported CIGAR op: %c", op);
                return NO;
        }
    }
    if (op == (char)0xFF) {
        rd_set_error(error, 112, @"REF_DIFF malformed CIGAR string");
        return NO;
    }
    return YES;
}

// ── Bit-pack one read's diff record ────────────────────────────────

static void rd_pack_read(const rd_walk_t *w, NSMutableData *out)
{
    // Number of bits = m_count + 8 * sub_count.
    size_t total_bits = w->flag_count + 8u * w->sub_count;
    size_t nbytes = (total_bits + 7) / 8;
    NSUInteger oldLen = out.length;
    [out setLength:oldLen + nbytes];
    uint8_t *dst = (uint8_t *)out.mutableBytes + oldLen;
    memset(dst, 0, nbytes);

    size_t bit_cursor = 0;
    size_t sub_idx = 0;
    for (size_t k = 0; k < w->flag_count; k++) {
        uint8_t flag = w->flag_bits[k];
        // Write flag bit.
        if (flag) {
            size_t byte = bit_cursor >> 3;
            size_t off  = bit_cursor & 7;
            dst[byte] |= (uint8_t)(1u << (7 - off));
        }
        bit_cursor++;
        if (flag) {
            uint8_t b = w->sub_bytes[sub_idx++];
            for (int s = 7; s >= 0; s--) {
                if ((b >> s) & 1) {
                    size_t byte = bit_cursor >> 3;
                    size_t off  = bit_cursor & 7;
                    dst[byte] |= (uint8_t)(1u << (7 - off));
                }
                bit_cursor++;
            }
        }
    }
    // I-op + S-op verbatim.
    if (w->ins_count) [out appendBytes:w->ins_bytes  length:w->ins_count];
    if (w->soft_count) [out appendBytes:w->soft_bytes length:w->soft_count];
}

// ── Bit-unpack one read's diff record ──────────────────────────────
//
// Caller supplies m_count (bits to read) + ins_total + soft_total (bytes
// after the bit stream). Returns the number of source bytes consumed,
// or SIZE_MAX on failure.

static size_t rd_unpack_read(const uint8_t *src, size_t src_len,
                              size_t m_count, size_t ins_total, size_t soft_total,
                              rd_walk_t *out,
                              NSError **error)
{
    rd_walk_init(out);
    out->flag_bits = (uint8_t *)calloc(m_count ? m_count : 1, 1);
    out->sub_bytes = (uint8_t *)malloc(m_count ? m_count : 1);

    size_t bit_cursor = 0;
    for (size_t k = 0; k < m_count; k++) {
        size_t byte = bit_cursor >> 3;
        size_t off  = bit_cursor & 7;
        if (byte >= src_len) {
            rd_set_error(error, 120,
                @"REF_DIFF bit stream truncated reading flag bit %zu", k);
            rd_walk_free(out);
            return SIZE_MAX;
        }
        uint8_t flag = (uint8_t)((src[byte] >> (7 - off)) & 1);
        out->flag_bits[out->flag_count++] = flag;
        bit_cursor++;
        if (flag) {
            uint8_t v = 0;
            for (int s = 0; s < 8; s++) {
                size_t b2 = bit_cursor >> 3;
                size_t o2 = bit_cursor & 7;
                if (b2 >= src_len) {
                    rd_set_error(error, 121,
                        @"REF_DIFF bit stream truncated reading sub byte at "
                        @"bit %zu", bit_cursor);
                    rd_walk_free(out);
                    return SIZE_MAX;
                }
                v = (uint8_t)((v << 1) | ((src[b2] >> (7 - o2)) & 1));
                bit_cursor++;
            }
            out->sub_bytes[out->sub_count++] = v;
        }
    }
    size_t bytes_consumed = (bit_cursor + 7) / 8;
    if (bytes_consumed + ins_total + soft_total > src_len) {
        rd_set_error(error, 122,
            @"REF_DIFF read body truncated: need %zu+%zu+%zu = %zu, have %zu",
            bytes_consumed, ins_total, soft_total,
            bytes_consumed + ins_total + soft_total, src_len);
        rd_walk_free(out);
        return SIZE_MAX;
    }
    if (ins_total) {
        out->ins_bytes = (uint8_t *)malloc(ins_total);
        memcpy(out->ins_bytes, src + bytes_consumed, ins_total);
        out->ins_count = ins_total;
    }
    if (soft_total) {
        out->soft_bytes = (uint8_t *)malloc(soft_total);
        memcpy(out->soft_bytes, src + bytes_consumed + ins_total, soft_total);
        out->soft_count = soft_total;
    }
    return bytes_consumed + ins_total + soft_total;
}

// ── Reconstruct one read sequence from its diff record + CIGAR ─────

static NSData *rd_reconstruct_read(const rd_walk_t *w,
                                    const char *cig, size_t cig_len,
                                    int64_t position,
                                    const uint8_t *ref, size_t ref_len,
                                    NSError **error)
{
    if (cig_len == 0 || (cig_len == 1 && cig[0] == '*')) {
        rd_set_error(error, 130, @"REF_DIFF cannot reconstruct unmapped read");
        return nil;
    }
    NSMutableData *out = [NSMutableData data];
    size_t flag_i = 0, sub_i = 0, ins_i = 0, soft_i = 0;
    int64_t ref_i = position - 1;

    size_t cur = 0;
    uint32_t L; char op;
    while (rd_cigar_next(cig, cig_len, &cur, &L, &op)) {
        switch (op) {
            case 'M': case '=': case 'X': {
                if (ref_i < 0 || (size_t)(ref_i + L) > ref_len) {
                    rd_set_error(error, 131,
                        @"REF_DIFF reconstruct: M-op out of ref bounds "
                        @"(ref_i=%lld+%u/%zu)",
                        (long long)ref_i, L, ref_len);
                    return nil;
                }
                for (uint32_t k = 0; k < L; k++) {
                    if (flag_i >= w->flag_count) {
                        rd_set_error(error, 132,
                            @"REF_DIFF reconstruct: flag underrun");
                        return nil;
                    }
                    uint8_t fb = w->flag_bits[flag_i++];
                    uint8_t out_byte;
                    if (fb == 0) {
                        out_byte = ref[(size_t)ref_i + k];
                    } else {
                        if (sub_i >= w->sub_count) {
                            rd_set_error(error, 133,
                                @"REF_DIFF reconstruct: substitution underrun");
                            return nil;
                        }
                        out_byte = w->sub_bytes[sub_i++];
                    }
                    [out appendBytes:&out_byte length:1];
                }
                ref_i += L;
                break;
            }
            case 'I':
                if (ins_i + L > w->ins_count) {
                    rd_set_error(error, 134,
                        @"REF_DIFF reconstruct: insertion underrun");
                    return nil;
                }
                [out appendBytes:w->ins_bytes + ins_i length:L];
                ins_i += L;
                break;
            case 'S':
                if (soft_i + L > w->soft_count) {
                    rd_set_error(error, 135,
                        @"REF_DIFF reconstruct: soft-clip underrun");
                    return nil;
                }
                [out appendBytes:w->soft_bytes + soft_i length:L];
                soft_i += L;
                break;
            case 'D': case 'N':
                ref_i += L;
                break;
            case 'H': case 'P':
                break;
            default:
                rd_set_error(error, 136,
                    @"REF_DIFF reconstruct: unsupported CIGAR op %c", op);
                return nil;
        }
    }
    return out;
}

// ── Per-slice encode/decode ────────────────────────────────────────

// Encode reads [lo, hi) into one rANS-compressed slice body.
static NSData *rd_encode_slice(NSArray<NSData *> *sequences,
                                NSArray<NSString *> *cigars,
                                const int64_t *positions,
                                const uint8_t *ref, size_t ref_len,
                                NSUInteger lo, NSUInteger hi,
                                NSError **error)
{
    NSMutableData *raw = [NSMutableData data];
    for (NSUInteger i = lo; i < hi; i++) {
        NSData *seq = sequences[i];
        NSString *cig = cigars[i];
        const char *cig_utf8 = [cig UTF8String];
        size_t cig_len = cig ? strlen(cig_utf8) : 0;
        rd_walk_t w;
        if (!rd_walk_read((const uint8_t *)seq.bytes, seq.length,
                           cig_utf8, cig_len, positions[i],
                           ref, ref_len, &w, error)) {
            return nil;
        }
        rd_pack_read(&w, raw);
        rd_walk_free(&w);
    }
    return TTIORansEncode(raw, 0);
}

static NSArray<NSData *> *rd_decode_slice(NSData *encoded,
                                           NSArray<NSString *> *cigars,
                                           const int64_t *positions,
                                           const uint8_t *ref, size_t ref_len,
                                           NSUInteger lo, NSUInteger hi,
                                           NSError **error)
{
    NSError *decErr = nil;
    NSData *raw = TTIORansDecode(encoded, &decErr);
    if (!raw) {
        if (error) *error = decErr ?: [NSError
            errorWithDomain:TTIORefDiffErrorDomain code:200
                   userInfo:@{NSLocalizedDescriptionKey:
                       @"REF_DIFF: rANS decode of slice body failed"}];
        return nil;
    }
    const uint8_t *src = (const uint8_t *)raw.bytes;
    size_t src_len = raw.length;
    NSMutableArray<NSData *> *out = [NSMutableArray arrayWithCapacity:hi - lo];
    size_t cursor = 0;
    for (NSUInteger i = lo; i < hi; i++) {
        NSString *cig = cigars[i];
        const char *cig_utf8 = [cig UTF8String];
        size_t cig_len = cig ? strlen(cig_utf8) : 0;
        size_t m_count, ins_total, soft_total;
        if (!rd_cigar_totals(cig_utf8, cig_len, &m_count, &ins_total, &soft_total, error)) {
            return nil;
        }
        rd_walk_t w;
        size_t consumed = rd_unpack_read(src + cursor, src_len - cursor,
                                          m_count, ins_total, soft_total,
                                          &w, error);
        if (consumed == SIZE_MAX) return nil;
        cursor += consumed;
        NSData *rec = rd_reconstruct_read(&w, cig_utf8, cig_len, positions[i],
                                           ref, ref_len, error);
        rd_walk_free(&w);
        if (!rec) return nil;
        [out addObject:rec];
    }
    return out;
}

// ── TTIORefDiff class ──────────────────────────────────────────────

@implementation TTIORefDiff

+ (nullable NSData *)encodeWithSequences:(NSArray<NSData *> *)sequences
                                  cigars:(NSArray<NSString *> *)cigars
                               positions:(NSData *)positions
                      referenceChromSeq:(NSData *)referenceChromSeq
                            referenceMD5:(NSData *)referenceMD5
                            referenceURI:(NSString *)referenceURI
                                   error:(NSError * _Nullable *)error
{
    NSUInteger n = sequences.count;
    if (cigars.count != n ||
        positions.length != n * sizeof(int64_t)) {
        rd_set_error(error, 300,
            @"REF_DIFF encode: parallel array length mismatch "
            @"(sequences=%lu, cigars=%lu, positions=%lu bytes / %lu int64s)",
            (unsigned long)n, (unsigned long)cigars.count,
            (unsigned long)positions.length,
            (unsigned long)(positions.length / sizeof(int64_t)));
        return nil;
    }
    if (referenceMD5.length != 16) {
        rd_set_error(error, 301,
            @"REF_DIFF encode: reference_md5 must be 16 bytes (got %lu)",
            (unsigned long)referenceMD5.length);
        return nil;
    }

    const int64_t *posArr  = (const int64_t *)positions.bytes;
    const uint8_t *ref     = (const uint8_t *)referenceChromSeq.bytes;
    size_t         ref_len = (size_t)referenceChromSeq.length;

    // Slice the reads.
    NSUInteger sliceSize = kRefDiffSliceSizeDefault;
    NSUInteger nSlices = n ? (n + sliceSize - 1) / sliceSize : 0;

    NSMutableArray<NSData *> *sliceBlobs = [NSMutableArray arrayWithCapacity:nSlices];
    NSMutableData *indexBlob = [NSMutableData dataWithCapacity:nSlices * kRefDiffSliceIndexEntrySize];
    uint64_t bodyOffset = 0;
    for (NSUInteger s = 0; s < nSlices; s++) {
        NSUInteger lo = s * sliceSize;
        NSUInteger hi = MIN(lo + sliceSize, n);
        NSData *body = rd_encode_slice(sequences, cigars, posArr,
                                        ref, ref_len, lo, hi, error);
        if (!body) return nil;

        rd_slice_entry_t e;
        e.body_offset    = bodyOffset;
        e.body_length    = (uint32_t)body.length;
        e.first_position = posArr[lo];
        e.last_position  = posArr[hi - 1];
        e.num_reads      = (uint32_t)(hi - lo);

        uint8_t entry[kRefDiffSliceIndexEntrySize];
        pack_slice_entry(entry, &e);
        [indexBlob appendBytes:entry length:kRefDiffSliceIndexEntrySize];
        [sliceBlobs addObject:body];
        bodyOffset += body.length;
    }

    TTIORefDiffCodecHeader *header = [[TTIORefDiffCodecHeader alloc]
        initWithNumSlices:(uint32_t)nSlices
                totalReads:(uint64_t)n
              referenceMD5:referenceMD5
              referenceURI:referenceURI];
    NSMutableData *out = [NSMutableData data];
    [out appendData:[header packedData]];
    [out appendData:indexBlob];
    for (NSData *body in sliceBlobs) [out appendData:body];
    return out;
}

+ (nullable NSArray<NSData *> *)decodeData:(NSData *)data
                                    cigars:(NSArray<NSString *> *)cigars
                                 positions:(NSData *)positions
                        referenceChromSeq:(NSData *)referenceChromSeq
                                     error:(NSError * _Nullable *)error
{
    NSUInteger headerEnd = 0;
    TTIORefDiffCodecHeader *h =
        [TTIORefDiffCodecHeader headerFromData:data
                                  bytesConsumed:&headerEnd
                                          error:error];
    if (!h) return nil;

    NSUInteger total = data.length;
    NSUInteger cursor = headerEnd;
    NSUInteger needIndex = (NSUInteger)h.numSlices * kRefDiffSliceIndexEntrySize;
    if (cursor + needIndex > total) {
        rd_set_error(error, 310,
            @"REF_DIFF: slice index truncated (need %lu + %lu = %lu, have %lu)",
            (unsigned long)cursor, (unsigned long)needIndex,
            (unsigned long)(cursor + needIndex), (unsigned long)total);
        return nil;
    }
    const uint8_t *base = (const uint8_t *)data.bytes;
    rd_slice_entry_t *entries = NULL;
    if (h.numSlices > 0) {
        entries = (rd_slice_entry_t *)calloc(h.numSlices, sizeof(rd_slice_entry_t));
        for (uint32_t s = 0; s < h.numSlices; s++) {
            unpack_slice_entry(base + cursor, &entries[s]);
            cursor += kRefDiffSliceIndexEntrySize;
        }
    }
    NSUInteger bodiesStart = cursor;

    if (positions.length != h.totalReads * sizeof(int64_t) ||
        cigars.count != h.totalReads) {
        free(entries);
        rd_set_error(error, 311,
            @"REF_DIFF decode: parallel array mismatch "
            @"(header total_reads=%llu, cigars=%lu, positions=%lu int64s)",
            (unsigned long long)h.totalReads, (unsigned long)cigars.count,
            (unsigned long)(positions.length / sizeof(int64_t)));
        return nil;
    }

    const int64_t *posArr  = (const int64_t *)positions.bytes;
    const uint8_t *ref     = (const uint8_t *)referenceChromSeq.bytes;
    size_t         ref_len = (size_t)referenceChromSeq.length;

    NSMutableArray<NSData *> *out = [NSMutableArray arrayWithCapacity:h.totalReads];
    NSUInteger readCursor = 0;
    for (uint32_t s = 0; s < h.numSlices; s++) {
        rd_slice_entry_t *e = &entries[s];
        NSUInteger bodyStart = bodiesStart + (NSUInteger)e->body_offset;
        NSUInteger bodyEnd   = bodyStart + (NSUInteger)e->body_length;
        if (bodyEnd > total) {
            free(entries);
            rd_set_error(error, 312,
                @"REF_DIFF: slice %u body out of range (end=%lu > total=%lu)",
                (unsigned)s, (unsigned long)bodyEnd, (unsigned long)total);
            return nil;
        }
        NSData *body = [data subdataWithRange:
            NSMakeRange(bodyStart, e->body_length)];
        NSArray<NSData *> *slice = rd_decode_slice(body, cigars, posArr,
                                                    ref, ref_len,
                                                    readCursor,
                                                    readCursor + e->num_reads,
                                                    error);
        if (!slice) {
            free(entries);
            return nil;
        }
        [out addObjectsFromArray:slice];
        readCursor += e->num_reads;
    }
    free(entries);
    return out;
}

@end
