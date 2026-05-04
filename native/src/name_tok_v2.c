/* NAME_TOKENIZED v2 codec implementation.
 * Spec: docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md
 */
#include "name_tok_v2.h"
#include "ttio_rans.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ──────── Helpers ──────── */

static int is_valid_num_run(const char *s, uint16_t len) {
    if (len == 1 && s[0] == '0') return 1;
    if (len >= 1 && s[0] == '0') return 0;
    return 1;
}

int ntv2_tokenise(const char *name,
                  uint8_t *types, uint16_t *starts, uint16_t *lens,
                  uint8_t *n_tokens, uint64_t *num_values) {
    if (name == NULL) return -1;
    size_t L = strlen(name);
    if (L == 0) { *n_tokens = 0; return 0; }
    if (L > 0xFFFF) return -1;
    /* Validate ASCII */
    for (size_t i = 0; i < L; i++) {
        unsigned char c = (unsigned char)name[i];
        if (c > 0x7F) return -1;
    }
    uint8_t n = 0;
    size_t i = 0;
    while (i < L) {
        if (n >= 255) return -1;
        if (isdigit((unsigned char)name[i])) {
            /* Find run end */
            size_t j = i;
            while (j < L && isdigit((unsigned char)name[j])) j++;
            uint16_t run_len = (uint16_t)(j - i);
            if (is_valid_num_run(name + i, run_len)) {
                /* Numeric token (try to parse) */
                uint64_t v = 0;
                int overflow = 0;
                for (size_t k = i; k < j; k++) {
                    if (v > (UINT64_MAX - 9) / 10) { overflow = 1; break; }
                    v = v * 10 + (uint64_t)(name[k] - '0');
                }
                if (overflow || v > 0x7FFFFFFFFFFFFFFFULL) {
                    /* Demote to string token; merge with surrounding */
                    if (n > 0 && types[n-1] == NTV2_TOK_STR) {
                        lens[n-1] = (uint16_t)(lens[n-1] + run_len);
                    } else {
                        types[n] = NTV2_TOK_STR;
                        starts[n] = (uint16_t)i;
                        lens[n] = run_len;
                        n++;
                    }
                } else {
                    types[n] = NTV2_TOK_NUM;
                    starts[n] = (uint16_t)i;
                    lens[n] = run_len;
                    num_values[n] = v;
                    n++;
                }
            } else {
                /* Invalid num — absorb into surrounding string */
                if (n > 0 && types[n-1] == NTV2_TOK_STR) {
                    lens[n-1] = (uint16_t)(lens[n-1] + run_len);
                } else {
                    types[n] = NTV2_TOK_STR;
                    starts[n] = (uint16_t)i;
                    lens[n] = run_len;
                    n++;
                }
            }
            i = j;
        } else {
            /* Walk a string run, absorbing invalid digit-runs */
            size_t j = i;
            while (j < L) {
                if (isdigit((unsigned char)name[j])) {
                    size_t k = j;
                    while (k < L && isdigit((unsigned char)name[k])) k++;
                    if (is_valid_num_run(name + j, (uint16_t)(k - j))) {
                        break;  /* valid num next — close current str */
                    }
                    j = k;  /* absorb invalid num */
                } else {
                    j++;
                }
            }
            uint16_t run_len = (uint16_t)(j - i);
            if (n > 0 && types[n-1] == NTV2_TOK_STR) {
                lens[n-1] = (uint16_t)(lens[n-1] + run_len);
            } else {
                types[n] = NTV2_TOK_STR;
                starts[n] = (uint16_t)i;
                lens[n] = run_len;
                n++;
            }
            i = j;
        }
    }
    *n_tokens = n;
    return 0;
}

size_t ntv2_pack_2bits(const uint8_t *vals, size_t n, uint8_t *out) {
    size_t out_bytes = (n * 2 + 7) / 8;
    memset(out, 0, out_bytes);
    for (size_t i = 0; i < n; i++) {
        size_t bit_pos = i * 2;
        size_t byte_idx = bit_pos / 8;
        int shift = 6 - (int)(bit_pos % 8);
        out[byte_idx] |= (uint8_t)((vals[i] & 3) << shift);
    }
    return out_bytes;
}

void ntv2_unpack_2bits(const uint8_t *in, size_t n, uint8_t *out) {
    for (size_t i = 0; i < n; i++) {
        size_t bit_pos = i * 2;
        size_t byte_idx = bit_pos / 8;
        int shift = 6 - (int)(bit_pos % 8);
        out[i] = (uint8_t)((in[byte_idx] >> shift) & 3);
    }
}

size_t ntv2_pack_3bits(const uint8_t *vals, size_t n, uint8_t *out) {
    size_t out_bytes = (n * 3 + 7) / 8;
    memset(out, 0, out_bytes);
    for (size_t i = 0; i < n; i++) {
        size_t bit_pos = i * 3;
        size_t byte_idx = bit_pos / 8;
        int in_byte = (int)(bit_pos % 8);
        if (in_byte + 3 <= 8) {
            int shift = 8 - in_byte - 3;
            out[byte_idx] |= (uint8_t)((vals[i] & 7) << shift);
        } else {
            int high_bits = 8 - in_byte;
            int low_bits = 3 - high_bits;
            uint8_t v = (uint8_t)(vals[i] & 7);
            out[byte_idx] |= (uint8_t)(v >> low_bits);
            out[byte_idx + 1] |= (uint8_t)((v & ((1U << low_bits) - 1)) << (8 - low_bits));
        }
    }
    return out_bytes;
}

void ntv2_unpack_3bits(const uint8_t *in, size_t n, uint8_t *out) {
    for (size_t i = 0; i < n; i++) {
        size_t bit_pos = i * 3;
        size_t byte_idx = bit_pos / 8;
        int in_byte = (int)(bit_pos % 8);
        if (in_byte + 3 <= 8) {
            int shift = 8 - in_byte - 3;
            out[i] = (uint8_t)((in[byte_idx] >> shift) & 7);
        } else {
            int high_bits = 8 - in_byte;
            int low_bits = 3 - high_bits;
            uint8_t high = (uint8_t)(in[byte_idx] & ((1U << high_bits) - 1));
            uint8_t low = (uint8_t)((in[byte_idx + 1] >> (8 - low_bits)) & ((1U << low_bits) - 1));
            out[i] = (uint8_t)((high << low_bits) | low);
        }
    }
}

size_t ntv2_uvarint_encode(uint64_t v, uint8_t *out) {
    size_t n = 0;
    while (v >= 0x80) { out[n++] = (uint8_t)((v & 0x7F) | 0x80); v >>= 7; }
    out[n++] = (uint8_t)v;
    return n;
}

size_t ntv2_uvarint_decode(const uint8_t *in, uint64_t *v) {
    uint64_t r = 0;
    int shift = 0;
    size_t n = 0;
    while (1) {
        uint8_t b = in[n++];
        r |= ((uint64_t)(b & 0x7F)) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift >= 64) { *v = 0; return 0; }
    }
    *v = r;
    return n;
}

size_t ntv2_svarint_encode(int64_t v, uint8_t *out) {
    uint64_t z = ((uint64_t)v << 1) ^ (uint64_t)(v >> 63);
    return ntv2_uvarint_encode(z, out);
}

size_t ntv2_svarint_decode(const uint8_t *in, int64_t *v) {
    uint64_t u;
    size_t n = ntv2_uvarint_decode(in, &u);
    *v = (int64_t)((u >> 1) ^ (~(u & 1) + 1));  /* zigzag inverse */
    return n;
}

/* ──────── Public entry stubs (Task 3 fills them) ──────── */

size_t ttio_name_tok_v2_max_encoded_size(uint64_t n_reads, uint64_t total_name_bytes) {
    /* Worst case: header + offsets + per-read overhead + verbatim copy + slack. */
    size_t hdr = NTV2_HEADER_FIXED + ((n_reads + NTV2_BLOCK_SIZE - 1) / NTV2_BLOCK_SIZE) * 4;
    size_t per_read_overhead = 32;
    size_t per_block_overhead = 64 * NTV2_SUB_COUNT;  /* substream headers */
    size_t n_blocks = (n_reads + NTV2_BLOCK_SIZE - 1) / NTV2_BLOCK_SIZE;
    return hdr + n_blocks * per_block_overhead + n_reads * per_read_overhead + total_name_bytes + 1024;
}

int ttio_name_tok_v2_encode(const char * const *names, uint64_t n_reads,
                            uint8_t *out, size_t *out_len) {
    (void)names; (void)n_reads; (void)out; (void)out_len;
    return TTIO_RANS_ERR_PARAM;  /* stub — Task 3 fills */
}

int ttio_name_tok_v2_decode(const uint8_t *encoded, size_t encoded_size,
                            char ***out_names, uint64_t *out_n_reads) {
    (void)encoded; (void)encoded_size; (void)out_names; (void)out_n_reads;
    return TTIO_RANS_ERR_PARAM;  /* stub */
}
