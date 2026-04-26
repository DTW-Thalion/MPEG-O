/*
 * TTIONameTokenizer.m — clean-room NAME_TOKENIZED genomic read-name codec.
 *
 * Lean two-token-type columnar implementation. Mirrors
 * python/src/ttio/codecs/name_tokenizer.py byte-for-byte. See the
 * header for the wire-format spec. No htslib / CRAM tools-Java /
 * SRA toolkit / samtools / Bonfield 2022 reference source consulted.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIONameTokenizer.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── Wire-format constants (HANDOFF M85B §3) ────────────────────────

enum {
    TTIO_NT_VERSION       = 0x00,
    TTIO_NT_SCHEME_LEAN   = 0x00,   // lean-columnar
    TTIO_NT_MODE_COLUMNAR = 0x00,
    TTIO_NT_MODE_VERBATIM = 0x01,
    TTIO_NT_HEADER_LEN    = 7,
    TTIO_NT_TYPE_NUMERIC  = 0,
    TTIO_NT_TYPE_STRING   = 1,
};

// Numeric tokens whose magnitude is >= this bound are demoted to
// string tokens (binding decision §104; delta arithmetic uses int64).
// Comparing the unsigned uint64 accumulator against this catches
// >= 2^63 values without UB.
static const uint64_t kNumericMax = (uint64_t)1 << 63;

static NSString * const kTTIONameTokenizerErrorDomain =
    @"TTIONameTokenizerError";

// ── Token representation ───────────────────────────────────────────
//
// One token = (type, payload). For numeric tokens, payload is the
// int64 value. For string tokens, payload is a pointer + length into
// the read's backing ASCII buffer (not a copy — the buffer outlives
// every Token derived from it during a single encode call).

typedef struct {
    uint8_t        type;       // 0 = numeric, 1 = string
    uint32_t       str_off;    // string token: byte offset in backing
    uint32_t       str_len;    // string token: byte length
    int64_t        num_value;  // numeric token: int64 value
} TTIONameToken;

// ── Varint and zigzag helpers ──────────────────────────────────────
//
// Unsigned LEB128 (low 7 bits first; top bit = continuation).
// Maximum encoded length for uint64 is 10 bytes.

static inline void varint_write(NSMutableData *out, uint64_t value)
{
    uint8_t buf[10];
    size_t n = 0;
    while (value >= 0x80u) {
        buf[n++] = (uint8_t)((value & 0x7Fu) | 0x80u);
        value >>= 7;
    }
    buf[n++] = (uint8_t)(value & 0x7Fu);
    [out appendBytes:buf length:n];
}

// Returns 1 on success, 0 on malformed input. On success, *out_value
// receives the decoded value and *io_offset is advanced past it.
static int varint_read(const uint8_t *buf, size_t buf_len,
                       size_t *io_offset, uint64_t *out_value)
{
    uint64_t value = 0;
    int shift = 0;
    size_t pos = *io_offset;
    for (;;) {
        if (pos >= buf_len) return 0;
        const uint8_t b = buf[pos++];
        if (shift >= 64) {
            // Would shift beyond 64 bits — malformed varint.
            return 0;
        }
        value |= ((uint64_t)(b & 0x7Fu)) << shift;
        if ((b & 0x80u) == 0) {
            *io_offset = pos;
            *out_value = value;
            return 1;
        }
        shift += 7;
    }
}

static inline uint64_t zigzag_encode_i64(int64_t n)
{
    // (n << 1) ^ (n >> 63). For negatives, n >> 63 == -1 (all 1s)
    // under arithmetic shift. C's >> on signed negative is impl-
    // defined; do it via cast to avoid UB.
    const uint64_t un = (uint64_t)n;
    const int64_t  sign = n >> 63;       // arithmetic shift on most
                                          // common platforms; we keep
                                          // a portable fallback below
    (void)sign;
    // Portable construction: high 64 bits sign mask via uint64 of -1
    // when n < 0 else 0.
    const uint64_t mask = (n < 0) ? (uint64_t)~(uint64_t)0 : (uint64_t)0;
    return (un << 1) ^ mask;
}

static inline int64_t zigzag_decode_i64(uint64_t n)
{
    return (int64_t)((n >> 1) ^ (~(n & 1) + 1));   // (n>>1) ^ -(n&1)
}

static inline void svarint_write(NSMutableData *out, int64_t value)
{
    varint_write(out, zigzag_encode_i64(value));
}

static int svarint_read(const uint8_t *buf, size_t buf_len,
                        size_t *io_offset, int64_t *out_value)
{
    uint64_t raw;
    if (!varint_read(buf, buf_len, io_offset, &raw)) return 0;
    *out_value = zigzag_decode_i64(raw);
    return 1;
}

// ── Error helper ───────────────────────────────────────────────────

static void ttio_nt_set_error(NSError * _Nullable * _Nullable outError,
                              NSInteger code,
                              NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void ttio_nt_set_error(NSError * _Nullable * _Nullable outError,
                              NSInteger code,
                              NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:kTTIONameTokenizerErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
#if !__has_feature(objc_arc)
    [msg release];
#endif
}

// ── Tokeniser (HANDOFF M85B §2.1) ──────────────────────────────────
//
// Tokens are stored in `tokens_out` (caller-owned buffer); the count
// is returned via *out_count. Each string token is a (offset, length)
// slice into `bytes` so the original ASCII buffer must outlive the
// tokens.
//
// Algorithm: walk the input in segments. At each step, read the
// maximal digit-run if the current byte is a digit, else the maximal
// non-digit run. A digit-run is a valid numeric token IFF
//   (a) length == 1 AND digit == '0', OR
//   (b) first digit != '0' AND value < 2^63.
// Otherwise the digit-run is absorbed into the surrounding string
// token. After parsing, tokens always alternate types.

static inline int is_digit(uint8_t c) { return c >= '0' && c <= '9'; }

// Try to parse digit-run [bytes+off, bytes+off+len) as int64; returns
// 1 on success (value fits in <2^63), else 0. Assumes len >= 1 and
// first byte is non-'0' (caller's job).
static int parse_digit_run(const uint8_t *bytes, uint32_t off,
                           uint32_t len, int64_t *out_value)
{
    uint64_t acc = 0;
    for (uint32_t i = 0; i < len; i++) {
        const uint8_t c = bytes[off + i];
        // Overflow check: acc * 10 + d < 2^63.
        // Bounding: if acc > (kNumericMax - 9) / 10, next step
        // overflows. Use the safer "compare against limit" form.
        if (acc > (kNumericMax - 9u) / 10u) {
            // Compute exact: acc*10 + d.
            const uint64_t step = acc * 10u + (uint64_t)(c - '0');
            if (step >= kNumericMax || step < acc) return 0;
            acc = step;
        } else {
            acc = acc * 10u + (uint64_t)(c - '0');
        }
    }
    if (acc >= kNumericMax) return 0;
    *out_value = (int64_t)acc;
    return 1;
}

// Tokenise a single read name. Allocates `*out_tokens` via malloc;
// caller must free. *out_count receives the token count.
static void tokenize_name(const uint8_t *bytes, uint32_t len,
                          TTIONameToken **out_tokens,
                          uint32_t *out_count)
{
    *out_tokens = NULL;
    *out_count = 0;
    if (len == 0) return;

    // Worst-case token count is len (every byte its own token, e.g.
    // "a1b2c3d4..." alternating). Allocate that bound up front; we
    // shrink later if it matters (it doesn't; freed shortly after).
    TTIONameToken *toks = (TTIONameToken *)malloc(sizeof(TTIONameToken) * len);
    if (!toks) return;
    uint32_t n = 0;

    // We accumulate "absorbed" bytes (raw bytes that belong to the
    // current pending string token) by extending its [off, len)
    // window. A pending string token, if present, is at toks[n-1]
    // with type STRING and (str_off, str_len) describing its window.

    uint32_t i = 0;
    while (i < len) {
        const uint32_t seg_start = i;
        if (is_digit(bytes[i])) {
            // Maximal digit-run.
            uint32_t j = i + 1;
            while (j < len && is_digit(bytes[j])) j++;
            const uint32_t run_len = j - seg_start;
            int valid_numeric = 0;
            int64_t value = 0;
            if (run_len == 1 && bytes[seg_start] == '0') {
                valid_numeric = 1;
                value = 0;
            } else if (bytes[seg_start] != '0') {
                if (parse_digit_run(bytes, seg_start, run_len, &value)) {
                    valid_numeric = 1;
                }
            }
            if (valid_numeric) {
                // Emit pending nothing (digit-runs can follow strings
                // or follow each other... but two adjacent numeric
                // tokens can't happen because between them must be a
                // non-digit byte). Just emit the numeric.
                toks[n].type = TTIO_NT_TYPE_NUMERIC;
                toks[n].num_value = value;
                toks[n].str_off = 0;
                toks[n].str_len = 0;
                n++;
            } else {
                // Absorb into the surrounding string token.
                if (n > 0 && toks[n - 1].type == TTIO_NT_TYPE_STRING) {
                    // Extend the previous string window.
                    toks[n - 1].str_len += run_len;
                } else {
                    toks[n].type = TTIO_NT_TYPE_STRING;
                    toks[n].str_off = seg_start;
                    toks[n].str_len = run_len;
                    toks[n].num_value = 0;
                    n++;
                }
            }
            i = j;
        } else {
            // Maximal non-digit run.
            uint32_t j = i + 1;
            while (j < len && !is_digit(bytes[j])) j++;
            const uint32_t run_len = j - seg_start;
            // A non-digit run is always part of a string token.
            // If the previous token is also a string (because we just
            // absorbed a leading-zero digit-run), extend it; else new.
            if (n > 0 && toks[n - 1].type == TTIO_NT_TYPE_STRING &&
                toks[n - 1].str_off + toks[n - 1].str_len == seg_start) {
                toks[n - 1].str_len += run_len;
            } else {
                toks[n].type = TTIO_NT_TYPE_STRING;
                toks[n].str_off = seg_start;
                toks[n].str_len = run_len;
                toks[n].num_value = 0;
                n++;
            }
            i = j;
        }
    }

    *out_tokens = toks;
    *out_count = n;
}

// ── ASCII validation ───────────────────────────────────────────────

static int is_ascii_string(NSString *s)
{
    // canBeConvertedToEncoding handles the empty-string case correctly.
    return [s canBeConvertedToEncoding:NSASCIIStringEncoding] ? 1 : 0;
}

// ── Encode ─────────────────────────────────────────────────────────

NSData *TTIONameTokenizerEncode(NSArray<NSString *> *names)
{
    if (names == nil) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIONameTokenizerEncode: names must not be nil"];
    }
    const NSUInteger n_reads_nu = [names count];
    if (n_reads_nu > 0xFFFFFFFFu) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIONameTokenizerEncode: n_reads %lu exceeds uint32 limit",
                            (unsigned long)n_reads_nu];
    }
    const uint32_t n_reads = (uint32_t)n_reads_nu;

    // Snapshot ASCII bytes for each name. dataUsingEncoding may return
    // nil for non-ASCII, in which case we raise.
    NSMutableArray<NSData *> *backingData =
        [NSMutableArray arrayWithCapacity:n_reads];
    for (uint32_t i = 0; i < n_reads; i++) {
        NSString *s = names[i];
        if (![s isKindOfClass:[NSString class]]) {
            [NSException raise:NSInvalidArgumentException
                        format:@"TTIONameTokenizerEncode: name at index %u is not NSString",
                                (unsigned)i];
        }
        if (!is_ascii_string(s)) {
            [NSException raise:NSInvalidArgumentException
                        format:@"TTIONameTokenizerEncode: name at index %u contains non-ASCII bytes",
                                (unsigned)i];
        }
        NSData *bytes = [s dataUsingEncoding:NSASCIIStringEncoding
                        allowLossyConversion:NO];
        if (bytes == nil) {
            // Belt-and-braces; should be caught by is_ascii_string above.
            [NSException raise:NSInvalidArgumentException
                        format:@"TTIONameTokenizerEncode: name at index %u failed ASCII conversion",
                                (unsigned)i];
        }
        [backingData addObject:bytes];
    }

    // Tokenise.
    TTIONameToken **tok_lists =
        (TTIONameToken **)calloc(n_reads ? n_reads : 1, sizeof(TTIONameToken *));
    uint32_t *tok_counts =
        (uint32_t *)calloc(n_reads ? n_reads : 1, sizeof(uint32_t));
    for (uint32_t i = 0; i < n_reads; i++) {
        NSData *d = backingData[i];
        tokenize_name((const uint8_t *)d.bytes, (uint32_t)d.length,
                      &tok_lists[i], &tok_counts[i]);
    }

    // Mode selection (HANDOFF §2.2 / gotcha §111).
    uint8_t mode = TTIO_NT_MODE_COLUMNAR;
    uint32_t n_columns = 0;
    uint8_t *type_table = NULL;

    if (n_reads == 0) {
        mode = TTIO_NT_MODE_COLUMNAR;
        n_columns = 0;
    } else {
        n_columns = tok_counts[0];
        // Same token count?
        for (uint32_t i = 1; i < n_reads; i++) {
            if (tok_counts[i] != n_columns) {
                mode = TTIO_NT_MODE_VERBATIM;
                break;
            }
        }
        if (mode == TTIO_NT_MODE_COLUMNAR && n_columns > 0xFF) {
            // n_columns must fit in uint8. If not, fall back to
            // verbatim. (Edge case unlikely in practice; preserves
            // round-trippability over the API.)
            mode = TTIO_NT_MODE_VERBATIM;
        }
        if (mode == TTIO_NT_MODE_COLUMNAR) {
            type_table = (uint8_t *)malloc(n_columns ? n_columns : 1);
            for (uint32_t c = 0; c < n_columns; c++) {
                type_table[c] = tok_lists[0][c].type;
            }
            // Per-column type match across reads?
            for (uint32_t i = 1; i < n_reads && mode == TTIO_NT_MODE_COLUMNAR; i++) {
                for (uint32_t c = 0; c < n_columns; c++) {
                    if (tok_lists[i][c].type != type_table[c]) {
                        mode = TTIO_NT_MODE_VERBATIM;
                        break;
                    }
                }
            }
        }
    }

    // Build output.
    NSMutableData *out = [NSMutableData dataWithCapacity:64];
    {
        uint8_t hdr[7];
        hdr[0] = TTIO_NT_VERSION;
        hdr[1] = TTIO_NT_SCHEME_LEAN;
        hdr[2] = mode;
        hdr[3] = (uint8_t)((n_reads >> 24) & 0xFFu);
        hdr[4] = (uint8_t)((n_reads >> 16) & 0xFFu);
        hdr[5] = (uint8_t)((n_reads >>  8) & 0xFFu);
        hdr[6] = (uint8_t)( n_reads        & 0xFFu);
        [out appendBytes:hdr length:7];
    }

    if (mode == TTIO_NT_MODE_COLUMNAR) {
        const uint8_t nc = (uint8_t)n_columns;
        [out appendBytes:&nc length:1];
        if (n_columns > 0) {
            [out appendBytes:type_table length:n_columns];
        }
        // Per-column streams.
        for (uint32_t c = 0; c < n_columns; c++) {
            if (type_table[c] == TTIO_NT_TYPE_NUMERIC) {
                if (n_reads == 0) continue;
                int64_t prev = tok_lists[0][c].num_value;
                varint_write(out, (uint64_t)prev);  // first value as
                                                      // unsigned varint
                                                      // (Python:
                                                      // _varint_encode);
                                                      // values < 2^63 so
                                                      // safe to cast
                for (uint32_t i = 1; i < n_reads; i++) {
                    int64_t cur = tok_lists[i][c].num_value;
                    int64_t delta = cur - prev;
                    svarint_write(out, delta);
                    prev = cur;
                }
            } else {
                // String column with per-column inline dictionary.
                NSMutableDictionary<NSData *, NSNumber *> *dict =
                    [NSMutableDictionary dictionary];
                NSData *backing0 = nil;  // unused
                (void)backing0;
                for (uint32_t i = 0; i < n_reads; i++) {
                    const TTIONameToken *t = &tok_lists[i][c];
                    NSData *backing = backingData[i];
                    NSData *tokenBytes =
                        [NSData dataWithBytesNoCopy:
                            (void *)((const uint8_t *)backing.bytes + t->str_off)
                                            length:t->str_len
                                      freeWhenDone:NO];
                    NSNumber *existing = dict[tokenBytes];
                    if (existing != nil) {
                        varint_write(out, (uint64_t)[existing unsignedLongLongValue]);
                    } else {
                        const uint64_t new_code = (uint64_t)[dict count];
                        // Store with a copied key so the dictionary
                        // owns stable bytes after this iteration.
                        NSData *keyCopy = [NSData dataWithBytes:tokenBytes.bytes
                                                         length:tokenBytes.length];
                        dict[keyCopy] = @(new_code);
                        varint_write(out, new_code);
                        varint_write(out, (uint64_t)t->str_len);
                        if (t->str_len > 0) {
                            [out appendBytes:tokenBytes.bytes length:t->str_len];
                        }
                    }
                }
            }
        }
    } else {
        // Verbatim body.
        for (uint32_t i = 0; i < n_reads; i++) {
            NSData *d = backingData[i];
            varint_write(out, (uint64_t)d.length);
            if (d.length > 0) {
                [out appendBytes:d.bytes length:d.length];
            }
        }
    }

    // Cleanup.
    for (uint32_t i = 0; i < n_reads; i++) {
        free(tok_lists[i]);
    }
    free(tok_lists);
    free(tok_counts);
    free(type_table);

    return out;
}

// ── Decode ─────────────────────────────────────────────────────────

// Convert int64 to decimal ASCII bytes. Writes up to 20 chars (sign
// + 19 digits for INT64_MIN). Returns the byte length; output is
// written to `dst` (must hold >= 21 bytes).
static inline size_t i64_to_decimal(int64_t v, uint8_t *dst)
{
    uint64_t u;
    int neg = 0;
    if (v < 0) {
        neg = 1;
        // Avoid UB on -INT64_MIN: cast first, then negate via two's
        // complement on the unsigned representation.
        u = (uint64_t)0 - (uint64_t)v;
    } else {
        u = (uint64_t)v;
    }
    uint8_t tmp[20];
    size_t n = 0;
    if (u == 0) {
        tmp[n++] = '0';
    } else {
        while (u > 0) {
            tmp[n++] = (uint8_t)('0' + (u % 10u));
            u /= 10u;
        }
    }
    size_t out = 0;
    if (neg) dst[out++] = '-';
    for (size_t i = 0; i < n; i++) {
        dst[out++] = tmp[n - 1 - i];
    }
    return out;
}

static NSArray<NSString *> *decode_columnar(const uint8_t *buf, size_t buf_len,
                                             size_t *io_off, uint32_t n_reads,
                                             NSError * _Nullable * _Nullable outErr)
{
    size_t off = *io_off;
    if (off >= buf_len) {
        ttio_nt_set_error(outErr, 10,
            @"NAME_TOKENIZED columnar body missing n_columns byte");
        return nil;
    }
    const uint32_t n_columns = buf[off++];
    if (off + n_columns > buf_len) {
        ttio_nt_set_error(outErr, 11,
            @"NAME_TOKENIZED columnar type table truncated: need %u bytes at offset %lu",
            (unsigned)n_columns, (unsigned long)off);
        return nil;
    }
    uint8_t *type_table = (uint8_t *)malloc(n_columns ? n_columns : 1);
    memcpy(type_table, buf + off, n_columns);
    off += n_columns;
    for (uint32_t c = 0; c < n_columns; c++) {
        if (type_table[c] != TTIO_NT_TYPE_NUMERIC &&
            type_table[c] != TTIO_NT_TYPE_STRING) {
            ttio_nt_set_error(outErr, 12,
                @"NAME_TOKENIZED unknown column type 0x%02x at column %u",
                (unsigned)type_table[c], (unsigned)c);
            free(type_table);
            return nil;
        }
    }

    if (n_reads == 0) {
        free(type_table);
        *io_off = off;
        return @[];
    }

    // Per-column materialisation. We accumulate each column's tokens
    // into either a numeric int64 array (decimal-formatting deferred
    // until row assembly) or a string-token slice array that points
    // into either the input buffer (literal entries) or a per-column
    // dictionary entry. This avoids producing intermediate NSStrings
    // for every token; instead, each row materialises ONE NSString
    // from a flat ASCII buffer.
    typedef struct {
        // For numeric columns: num_value is the int64 value; ptr/len unused.
        // For string columns: ptr/len describe the token bytes (slice
        // into either the input buffer or a dict entry's bytes).
        int64_t  num_value;
        const uint8_t *ptr;
        uint32_t       len;
    } ColCell;

    ColCell **cells = (ColCell **)calloc(n_columns ? n_columns : 1, sizeof(ColCell *));
    for (uint32_t c = 0; c < n_columns; c++) {
        cells[c] = (ColCell *)calloc(n_reads, sizeof(ColCell));
    }

    // Per-column string dictionaries: arrays of (ptr, len) slices into
    // the input buffer (the literal bytes). Allocated lazily per col.
    typedef struct {
        const uint8_t *ptr;
        uint32_t       len;
    } DictEntry;
    DictEntry **dict_arrs = (DictEntry **)calloc(
        n_columns ? n_columns : 1, sizeof(DictEntry *));
    uint32_t *dict_caps = (uint32_t *)calloc(
        n_columns ? n_columns : 1, sizeof(uint32_t));
    uint32_t *dict_sizes = (uint32_t *)calloc(
        n_columns ? n_columns : 1, sizeof(uint32_t));

    int decode_error = 0;
    NSInteger err_code = 0;
    NSString *err_msg = nil;

    for (uint32_t c = 0; c < n_columns && !decode_error; c++) {
        if (type_table[c] == TTIO_NT_TYPE_NUMERIC) {
            uint64_t seed_u;
            if (!varint_read(buf, buf_len, &off, &seed_u)) {
                err_code = 13;
                err_msg = [NSString stringWithFormat:
                    @"NAME_TOKENIZED numeric seed varint truncated at column %u",
                    (unsigned)c];
                decode_error = 1;
                break;
            }
            int64_t prev = (int64_t)seed_u;
            cells[c][0].num_value = prev;
            for (uint32_t i = 1; i < n_reads; i++) {
                int64_t delta;
                if (!svarint_read(buf, buf_len, &off, &delta)) {
                    err_code = 14;
                    err_msg = [NSString stringWithFormat:
                        @"NAME_TOKENIZED numeric delta varint truncated at column %u row %u",
                        (unsigned)c, (unsigned)i];
                    decode_error = 1;
                    break;
                }
                int64_t cur = prev + delta;
                cells[c][i].num_value = cur;
                prev = cur;
            }
        } else {
            for (uint32_t i = 0; i < n_reads; i++) {
                uint64_t code;
                if (!varint_read(buf, buf_len, &off, &code)) {
                    err_code = 15;
                    err_msg = [NSString stringWithFormat:
                        @"NAME_TOKENIZED string code varint truncated at column %u row %u",
                        (unsigned)c, (unsigned)i];
                    decode_error = 1;
                    break;
                }
                const uint64_t cur_size = (uint64_t)dict_sizes[c];
                if (code < cur_size) {
                    cells[c][i].ptr = dict_arrs[c][(uint32_t)code].ptr;
                    cells[c][i].len = dict_arrs[c][(uint32_t)code].len;
                } else if (code == cur_size) {
                    uint64_t length;
                    if (!varint_read(buf, buf_len, &off, &length)) {
                        err_code = 16;
                        err_msg = [NSString stringWithFormat:
                            @"NAME_TOKENIZED string literal length varint truncated at column %u row %u",
                            (unsigned)c, (unsigned)i];
                        decode_error = 1;
                        break;
                    }
                    if (length > buf_len || off + length > buf_len) {
                        err_code = 17;
                        err_msg = [NSString stringWithFormat:
                            @"NAME_TOKENIZED string literal runs off end of stream at column %u row %u",
                            (unsigned)c, (unsigned)i];
                        decode_error = 1;
                        break;
                    }
                    // Validate ASCII strictly.
                    const uint8_t *lit_ptr = buf + off;
                    for (uint64_t k = 0; k < length; k++) {
                        if (lit_ptr[k] & 0x80u) {
                            err_code = 18;
                            err_msg = [NSString stringWithFormat:
                                @"NAME_TOKENIZED string literal contains non-ASCII bytes at column %u row %u",
                                (unsigned)c, (unsigned)i];
                            decode_error = 1;
                            break;
                        }
                    }
                    if (decode_error) break;
                    off += (size_t)length;
                    // Append to per-column dictionary (grow as needed).
                    if (dict_sizes[c] >= dict_caps[c]) {
                        const uint32_t new_cap = dict_caps[c] ?
                            dict_caps[c] * 2 : 8;
                        dict_arrs[c] = (DictEntry *)realloc(
                            dict_arrs[c], sizeof(DictEntry) * new_cap);
                        dict_caps[c] = new_cap;
                    }
                    dict_arrs[c][dict_sizes[c]].ptr = lit_ptr;
                    dict_arrs[c][dict_sizes[c]].len = (uint32_t)length;
                    dict_sizes[c]++;
                    cells[c][i].ptr = lit_ptr;
                    cells[c][i].len = (uint32_t)length;
                } else {
                    err_code = 19;
                    err_msg = [NSString stringWithFormat:
                        @"NAME_TOKENIZED string code %llu > current dict size %llu at column %u row %u (malformed)",
                        (unsigned long long)code,
                        (unsigned long long)cur_size,
                        (unsigned)c, (unsigned)i];
                    decode_error = 1;
                    break;
                }
            }
        }
    }

    if (decode_error) {
        ttio_nt_set_error(outErr, err_code, @"%@", err_msg);
        for (uint32_t c = 0; c < n_columns; c++) {
            free(cells[c]);
            free(dict_arrs[c]);
        }
        free(cells);
        free(dict_arrs);
        free(dict_caps);
        free(dict_sizes);
        free(type_table);
        return nil;
    }

    NSMutableArray<NSString *> *names =
        [NSMutableArray arrayWithCapacity:n_reads];
    // Reusable row buffer; grows as needed.
    size_t row_cap = 256;
    uint8_t *row_buf = (uint8_t *)malloc(row_cap);
    for (uint32_t i = 0; i < n_reads; i++) {
        size_t row_len = 0;
        for (uint32_t c = 0; c < n_columns; c++) {
            if (type_table[c] == TTIO_NT_TYPE_NUMERIC) {
                if (row_len + 21 > row_cap) {
                    row_cap = (row_len + 21) * 2;
                    row_buf = (uint8_t *)realloc(row_buf, row_cap);
                }
                row_len += i64_to_decimal(cells[c][i].num_value,
                                          row_buf + row_len);
            } else {
                const uint32_t add = cells[c][i].len;
                if (row_len + add > row_cap) {
                    row_cap = (row_len + add) * 2;
                    row_buf = (uint8_t *)realloc(row_buf, row_cap);
                }
                if (add > 0) {
                    memcpy(row_buf + row_len, cells[c][i].ptr, add);
                    row_len += add;
                }
            }
        }
        NSString *s = [[NSString alloc] initWithBytes:row_buf
                                               length:row_len
                                             encoding:NSASCIIStringEncoding];
        if (s == nil) {
            // Should be unreachable: numeric chars are ASCII; string
            // tokens validated as ASCII at decode-literal time.
            free(row_buf);
            for (uint32_t c = 0; c < n_columns; c++) {
                free(cells[c]);
                free(dict_arrs[c]);
            }
            free(cells);
            free(dict_arrs);
            free(dict_caps);
            free(dict_sizes);
            free(type_table);
            ttio_nt_set_error(outErr, 23,
                @"NAME_TOKENIZED row reassembly produced non-ASCII bytes at row %u",
                (unsigned)i);
            return nil;
        }
        [names addObject:s];
#if !__has_feature(objc_arc)
        [s release];
#endif
    }
    free(row_buf);
    for (uint32_t c = 0; c < n_columns; c++) {
        free(cells[c]);
        free(dict_arrs[c]);
    }
    free(cells);
    free(dict_arrs);
    free(dict_caps);
    free(dict_sizes);
    free(type_table);

    *io_off = off;
    return names;
}

static NSArray<NSString *> *decode_verbatim(const uint8_t *buf, size_t buf_len,
                                             size_t *io_off, uint32_t n_reads,
                                             NSError * _Nullable * _Nullable outErr)
{
    size_t off = *io_off;
    NSMutableArray<NSString *> *names =
        [NSMutableArray arrayWithCapacity:n_reads];
    for (uint32_t i = 0; i < n_reads; i++) {
        uint64_t length;
        if (!varint_read(buf, buf_len, &off, &length)) {
            ttio_nt_set_error(outErr, 20,
                @"NAME_TOKENIZED verbatim length varint truncated at read %u",
                (unsigned)i);
            return nil;
        }
        if (length > buf_len || off + length > buf_len) {
            ttio_nt_set_error(outErr, 21,
                @"NAME_TOKENIZED verbatim entry runs off end of stream at read %u",
                (unsigned)i);
            return nil;
        }
        NSString *text = [[NSString alloc]
            initWithBytes:buf + off
                   length:(NSUInteger)length
                 encoding:NSASCIIStringEncoding];
        if (text == nil) {
            ttio_nt_set_error(outErr, 22,
                @"NAME_TOKENIZED verbatim entry contains non-ASCII bytes at read %u",
                (unsigned)i);
            return nil;
        }
        off += (size_t)length;
        [names addObject:text];
#if !__has_feature(objc_arc)
        [text release];
#endif
    }
    *io_off = off;
    return names;
}

NSArray<NSString *> * _Nullable TTIONameTokenizerDecode(
    NSData *encoded, NSError * _Nullable * _Nullable error)
{
    if (encoded == nil) {
        ttio_nt_set_error(error, 1,
            @"NAME_TOKENIZED stream too short for header: 0 < %d",
            TTIO_NT_HEADER_LEN);
        return nil;
    }
    const size_t enc_len = (size_t)encoded.length;
    if (enc_len < (size_t)TTIO_NT_HEADER_LEN) {
        ttio_nt_set_error(error, 1,
            @"NAME_TOKENIZED stream too short for header: %lu < %d",
            (unsigned long)enc_len, TTIO_NT_HEADER_LEN);
        return nil;
    }
    const uint8_t *buf = (const uint8_t *)encoded.bytes;
    const uint8_t version = buf[0];
    if (version != TTIO_NT_VERSION) {
        ttio_nt_set_error(error, 2,
            @"NAME_TOKENIZED bad version byte: 0x%02x (expected 0x%02x)",
            (unsigned)version, (unsigned)TTIO_NT_VERSION);
        return nil;
    }
    const uint8_t scheme_id = buf[1];
    if (scheme_id != TTIO_NT_SCHEME_LEAN) {
        ttio_nt_set_error(error, 3,
            @"NAME_TOKENIZED unknown scheme_id: 0x%02x (only 0x%02x = 'lean-columnar' is defined)",
            (unsigned)scheme_id, (unsigned)TTIO_NT_SCHEME_LEAN);
        return nil;
    }
    const uint8_t mode = buf[2];
    const uint32_t n_reads = ((uint32_t)buf[3] << 24) |
                             ((uint32_t)buf[4] << 16) |
                             ((uint32_t)buf[5] <<  8) |
                             ((uint32_t)buf[6]);

    size_t off = TTIO_NT_HEADER_LEN;
    NSArray<NSString *> *names = nil;
    if (mode == TTIO_NT_MODE_COLUMNAR) {
        names = decode_columnar(buf, enc_len, &off, n_reads, error);
    } else if (mode == TTIO_NT_MODE_VERBATIM) {
        names = decode_verbatim(buf, enc_len, &off, n_reads, error);
    } else {
        ttio_nt_set_error(error, 4,
            @"NAME_TOKENIZED bad mode byte: 0x%02x (expected 0x00 columnar or 0x01 verbatim)",
            (unsigned)mode);
        return nil;
    }

    if (names == nil) return nil;

    if (off != enc_len) {
        ttio_nt_set_error(error, 5,
            @"NAME_TOKENIZED trailing bytes: consumed %lu of %lu",
            (unsigned long)off, (unsigned long)enc_len);
        return nil;
    }
    return names;
}
