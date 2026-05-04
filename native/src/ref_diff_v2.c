#include "ref_diff_v2.h"
#include "../include/ttio_rans.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── ACGT 2-bit mapping ────────────────────────────────────────── */

uint8_t rdv2_base_to_2bit(uint8_t base) {
    /* upper-case normalisation */
    if (base >= 'a' && base <= 'z') base -= 32;
    switch (base) {
        case 'A': return RDV2_BASE_A;
        case 'C': return RDV2_BASE_C;
        case 'G': return RDV2_BASE_G;
        case 'T': return RDV2_BASE_T;
        default:  return RDV2_BASE_INVALID;
    }
}

uint8_t rdv2_2bit_to_base(uint8_t code) {
    static const uint8_t table[4] = {'A', 'C', 'G', 'T'};
    return (code < 4) ? table[code] : 'N';
}

/* ── 2-bit pack/unpack (LSB-first within byte) ──────────────────── */

size_t rdv2_pack_2bit(const uint8_t *codes, uint64_t n_codes, uint8_t *out) {
    size_t n_bytes = (n_codes + 3) / 4;
    memset(out, 0, n_bytes);
    for (uint64_t i = 0; i < n_codes; i++) {
        size_t byte_idx = i / 4;
        size_t bit_pos = (i % 4) * 2;
        out[byte_idx] |= (uint8_t)((codes[i] & 0x3) << bit_pos);
    }
    return n_bytes;
}

void rdv2_unpack_2bit(const uint8_t *in, uint64_t n_codes, uint8_t *out_codes) {
    for (uint64_t i = 0; i < n_codes; i++) {
        size_t byte_idx = i / 4;
        size_t bit_pos = (i % 4) * 2;
        out_codes[i] = (in[byte_idx] >> bit_pos) & 0x3;
    }
}

/* ── Cigar parser — counts only ─────────────────────────────────── */

int rdv2_parse_cigar_counts(const char *cigar,
                            uint64_t *out_match_count,
                            uint64_t *out_ins_count,
                            uint64_t *out_sc_count) {
    *out_match_count = 0;
    *out_ins_count = 0;
    *out_sc_count = 0;
    if (!cigar) return 0;
    const char *p = cigar;
    while (*p) {
        uint64_t length = 0;
        if (*p < '0' || *p > '9') return -1;
        while (*p >= '0' && *p <= '9') {
            length = length * 10 + (uint64_t)(*p - '0');
            p++;
        }
        char op = *p++;
        switch (op) {
            case 'M': case '=': case 'X':
                *out_match_count += length; break;
            case 'I':
                *out_ins_count += length; break;
            case 'S':
                *out_sc_count += length; break;
            case 'D': case 'N': case 'H': case 'P':
                break;
            default:
                return -1;
        }
    }
    return 0;
}

/* ── LE read/write helpers ──────────────────────────────────────── */

static void rdv2_w16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void rdv2_w32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static void rdv2_w64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)((v >> (i * 8)) & 0xff);
}
static uint16_t rdv2_r16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }
static uint32_t rdv2_r32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t rdv2_r64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= ((uint64_t)p[i]) << (i * 8);
    return v;
}

/* ── Varint (LEB128) ────────────────────────────────────────────── */

static size_t rdv2_varint_encode(uint64_t value, uint8_t *out) {
    size_t i = 0;
    while (value >= 0x80) { out[i++] = (uint8_t)(value | 0x80); value >>= 7; }
    out[i++] = (uint8_t)value;
    return i;
}

static int rdv2_varint_decode(const uint8_t *in, size_t in_len,
                              uint64_t *out_value, size_t *out_consumed) {
    uint64_t result = 0;
    size_t i = 0;
    int shift = 0;
    while (i < in_len) {
        uint8_t b = in[i++];
        result |= ((uint64_t)(b & 0x7F)) << shift;
        if ((b & 0x80) == 0) { *out_value = result; *out_consumed = i; return 0; }
        shift += 7;
        if (shift >= 64) return TTIO_RANS_ERR_CORRUPT;
    }
    return TTIO_RANS_ERR_CORRUPT;
}

/* ── max_encoded_size (unchanged) ───────────────────────────────── */

size_t ttio_ref_diff_v2_max_encoded_size(uint64_t n_reads, uint64_t total_bases) {
    /* Generous bound covering header + slice index + bodies */
    uint64_t n_slices = (n_reads + 9999) / 10000;
    if (n_slices == 0) n_slices = 1;
    return 4096 + 38 + n_slices * (32 + 24 + 4 * 1037 + total_bases / n_slices + 1024);
}

/* ── Per-slice encoder ──────────────────────────────────────────── */

static int rdv2_encode_slice(
    const uint8_t  *sequences,
    const uint64_t *offsets,
    const int64_t  *positions,
    const char    **cigar_strings,
    uint64_t        first_read,
    uint64_t        n_reads_in_slice,
    const uint8_t  *reference,
    uint64_t        reference_length,
    uint8_t        *out,
    size_t          out_capacity,
    size_t         *out_size)
{
    /* Pass 1: count */
    uint64_t total_match = 0, total_ins = 0, total_sc = 0;
    for (uint64_t r = 0; r < n_reads_in_slice; r++) {
        uint64_t m, ins, s;
        if (rdv2_parse_cigar_counts(cigar_strings[first_read + r], &m, &ins, &s) != 0)
            return TTIO_RANS_ERR_PARAM;
        total_match += m; total_ins += ins; total_sc += s;
    }

    /* Allocate buffers (use malloc(1) for empty so free is always safe) */
    uint8_t *flag_buf = malloc(total_match ? total_match : 1);
    uint8_t *bs_codes = malloc(total_match ? total_match : 1);
    uint8_t *in_codes = malloc(total_ins ? total_ins : 1);
    uint8_t *sc_codes = malloc(total_sc ? total_sc : 1);
    /* ESC: worst case 1 stream_id + ~10 varint bytes + 1 literal per base */
    uint8_t *esc_buf = malloc((total_match + total_ins + total_sc) * 12 + 16);
    uint8_t *bs_packed = NULL, *in_packed = NULL, *sc_packed = NULL;
    uint8_t *flag_rans = NULL, *bs_rans = NULL, *in_rans = NULL, *sc_rans = NULL, *esc_rans = NULL;
    int rc = 0;

    if (!flag_buf || !bs_codes || !in_codes || !sc_codes || !esc_buf) {
        rc = TTIO_RANS_ERR_ALLOC; goto cleanup;
    }

    uint64_t flag_n = 0, bs_n = 0, in_n = 0, sc_n = 0;
    size_t esc_size = 0;

    /* Pass 2: walk reads + cigars */
    for (uint64_t r = 0; r < n_reads_in_slice; r++) {
        uint64_t gid = first_read + r;
        const uint8_t *read = sequences + offsets[gid];
        uint64_t read_len = offsets[gid + 1] - offsets[gid];
        const char *cigar = cigar_strings[gid];
        int64_t ref_pos = positions[gid] - 1;  /* 1-based → 0-based */
        uint64_t read_pos = 0;

        const char *p = cigar;
        while (*p) {
            uint64_t length = 0;
            while (*p >= '0' && *p <= '9') { length = length * 10 + (uint64_t)(*p - '0'); p++; }
            char op = *p++;
            switch (op) {
                case 'M': case '=': case 'X':
                    for (uint64_t k = 0; k < length; k++) {
                        if ((uint64_t)ref_pos >= reference_length || read_pos >= read_len) {
                            rc = TTIO_RANS_ERR_PARAM; goto cleanup;
                        }
                        uint8_t rb = read[read_pos];
                        uint8_t fb = reference[ref_pos];
                        uint8_t rb_n = (rb >= 'a' && rb <= 'z') ? (uint8_t)(rb - 32) : rb;
                        uint8_t fb_n = (fb >= 'a' && fb <= 'z') ? (uint8_t)(fb - 32) : fb;
                        if (rb_n == fb_n) {
                            flag_buf[flag_n++] = 0;
                        } else {
                            flag_buf[flag_n++] = 1;
                            uint8_t code = rdv2_base_to_2bit(rb);
                            if (code == RDV2_BASE_INVALID) {
                                bs_codes[bs_n] = 0;  /* placeholder */
                                esc_buf[esc_size++] = RDV2_ESC_BS;
                                esc_size += rdv2_varint_encode(bs_n, esc_buf + esc_size);
                                esc_buf[esc_size++] = rb;
                            } else {
                                bs_codes[bs_n] = code;
                            }
                            bs_n++;
                        }
                        read_pos++;
                        ref_pos++;
                    }
                    break;
                case 'I':
                    for (uint64_t k = 0; k < length; k++) {
                        if (read_pos >= read_len) { rc = TTIO_RANS_ERR_PARAM; goto cleanup; }
                        uint8_t rb = read[read_pos];
                        uint8_t code = rdv2_base_to_2bit(rb);
                        if (code == RDV2_BASE_INVALID) {
                            in_codes[in_n] = 0;  /* placeholder */
                            esc_buf[esc_size++] = RDV2_ESC_IN;
                            esc_size += rdv2_varint_encode(in_n, esc_buf + esc_size);
                            esc_buf[esc_size++] = rb;
                        } else {
                            in_codes[in_n] = code;
                        }
                        in_n++;
                        read_pos++;
                    }
                    break;
                case 'S':
                    for (uint64_t k = 0; k < length; k++) {
                        if (read_pos >= read_len) { rc = TTIO_RANS_ERR_PARAM; goto cleanup; }
                        uint8_t rb = read[read_pos];
                        uint8_t code = rdv2_base_to_2bit(rb);
                        if (code == RDV2_BASE_INVALID) {
                            sc_codes[sc_n] = 0;  /* placeholder */
                            esc_buf[esc_size++] = RDV2_ESC_SC;
                            esc_size += rdv2_varint_encode(sc_n, esc_buf + esc_size);
                            esc_buf[esc_size++] = rb;
                        } else {
                            sc_codes[sc_n] = code;
                        }
                        sc_n++;
                        read_pos++;
                    }
                    break;
                case 'D': case 'N': ref_pos += (int64_t)length; break;
                case 'H': case 'P': break;
                default: rc = TTIO_RANS_ERR_PARAM; goto cleanup;
            }
        }
    }

    /* Pack BS / IN / SC */
    bs_packed = malloc((bs_n + 3) / 4 + 1);
    in_packed = malloc((in_n + 3) / 4 + 1);
    sc_packed = malloc((sc_n + 3) / 4 + 1);
    if (!bs_packed || !in_packed || !sc_packed) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
    size_t bs_packed_len = rdv2_pack_2bit(bs_codes, bs_n, bs_packed);
    size_t in_packed_len = rdv2_pack_2bit(in_codes, in_n, in_packed);
    size_t sc_packed_len = rdv2_pack_2bit(sc_codes, sc_n, sc_packed);

    /* rANS-O0 each substream */
    size_t flag_cap = ttio_rans_o0_max_encoded_size(flag_n ? flag_n : 1);
    size_t bs_cap   = ttio_rans_o0_max_encoded_size(bs_packed_len ? bs_packed_len : 1);
    size_t in_cap   = ttio_rans_o0_max_encoded_size(in_packed_len ? in_packed_len : 1);
    size_t sc_cap   = ttio_rans_o0_max_encoded_size(sc_packed_len ? sc_packed_len : 1);
    size_t esc_cap  = ttio_rans_o0_max_encoded_size(esc_size ? esc_size : 1);
    flag_rans = malloc(flag_cap);
    bs_rans   = malloc(bs_cap);
    in_rans   = malloc(in_cap);
    sc_rans   = malloc(sc_cap);
    esc_rans  = malloc(esc_cap);
    if (!flag_rans || !bs_rans || !in_rans || !sc_rans || !esc_rans) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
    size_t flag_rans_len = flag_cap, bs_rans_len = bs_cap;
    size_t in_rans_len = in_cap, sc_rans_len = sc_cap, esc_rans_len = esc_cap;
    rc = ttio_rans_o0_encode(flag_buf, flag_n, flag_rans, &flag_rans_len);
    if (!rc) rc = ttio_rans_o0_encode(bs_packed, bs_packed_len, bs_rans, &bs_rans_len);
    if (!rc) rc = ttio_rans_o0_encode(in_packed, in_packed_len, in_rans, &in_rans_len);
    if (!rc) rc = ttio_rans_o0_encode(sc_packed, sc_packed_len, sc_rans, &sc_rans_len);
    if (!rc) rc = ttio_rans_o0_encode(esc_buf, esc_size, esc_rans, &esc_rans_len);
    if (rc != 0) goto cleanup;

    /* Assemble slice body */
    size_t total = RDV2_SLICE_SUBHDR + flag_rans_len + bs_rans_len + in_rans_len + sc_rans_len + esc_rans_len;
    if (out_capacity < total) { rc = TTIO_RANS_ERR_PARAM; goto cleanup; }
    rdv2_w32(out + 0,  (uint32_t)flag_rans_len);
    rdv2_w32(out + 4,  (uint32_t)bs_rans_len);
    rdv2_w32(out + 8,  (uint32_t)in_rans_len);
    rdv2_w32(out + 12, (uint32_t)sc_rans_len);
    rdv2_w32(out + 16, (uint32_t)esc_rans_len);
    rdv2_w32(out + 20, 0);  /* reserved */
    size_t off = RDV2_SLICE_SUBHDR;
    memcpy(out + off, flag_rans, flag_rans_len); off += flag_rans_len;
    memcpy(out + off, bs_rans,   bs_rans_len);   off += bs_rans_len;
    memcpy(out + off, in_rans,   in_rans_len);   off += in_rans_len;
    memcpy(out + off, sc_rans,   sc_rans_len);   off += sc_rans_len;
    memcpy(out + off, esc_rans,  esc_rans_len);  off += esc_rans_len;
    *out_size = off;

cleanup:
    free(flag_buf); free(bs_codes); free(in_codes); free(sc_codes); free(esc_buf);
    free(bs_packed); free(in_packed); free(sc_packed);
    free(flag_rans); free(bs_rans); free(in_rans); free(sc_rans); free(esc_rans);
    return rc;
}

/* ── Top-level encoder ──────────────────────────────────────────── */

int ttio_ref_diff_v2_encode(
    const ttio_ref_diff_v2_input *in, uint8_t *out, size_t *out_len)
{
    if (!in || !out || !out_len) return TTIO_RANS_ERR_PARAM;
    if (!in->reference_md5 || !in->reference_uri) return TTIO_RANS_ERR_PARAM;
    size_t uri_len = strlen(in->reference_uri);
    if (uri_len > 0xFFFF) return TTIO_RANS_ERR_PARAM;
    uint64_t reads_per_slice = in->reads_per_slice ? in->reads_per_slice : 10000;
    uint64_t n_slices = in->n_reads == 0 ? 0 : (in->n_reads + reads_per_slice - 1) / reads_per_slice;

    size_t out_capacity = *out_len;
    size_t header_len = RDV2_OUTER_FIXED + uri_len;
    if (out_capacity < header_len + n_slices * RDV2_SLICE_INDEX_ENTRY)
        return TTIO_RANS_ERR_PARAM;

    /* Outer header (spec §4.3) */
    memcpy(out + 0, RDV2_MAGIC, 4);
    out[4] = RDV2_VERSION;
    out[5] = out[6] = out[7] = 0;
    rdv2_w32(out + 8,  (uint32_t)n_slices);
    rdv2_w64(out + 12, in->n_reads);
    memcpy(out + 20, in->reference_md5, 16);
    rdv2_w16(out + 36, (uint16_t)uri_len);
    memcpy(out + 38, in->reference_uri, uri_len);

    size_t slice_index_off  = header_len;
    size_t slice_bodies_off = slice_index_off + n_slices * RDV2_SLICE_INDEX_ENTRY;
    size_t cur = slice_bodies_off;

    for (uint64_t s = 0; s < n_slices; s++) {
        uint64_t first_read = s * reads_per_slice;
        uint64_t n_in_slice = in->n_reads - first_read;
        if (n_in_slice > reads_per_slice) n_in_slice = reads_per_slice;

        size_t slice_body_size = 0;
        int rc = rdv2_encode_slice(
            in->sequences, in->offsets, in->positions, in->cigar_strings,
            first_read, n_in_slice, in->reference, in->reference_length,
            out + cur, out_capacity - cur, &slice_body_size);
        if (rc != 0) return rc;

        /* Fill slice index entry */
        uint8_t *idx = out + slice_index_off + s * RDV2_SLICE_INDEX_ENTRY;
        rdv2_w64(idx + 0,  (uint64_t)(cur - slice_bodies_off));
        rdv2_w32(idx + 8,  (uint32_t)slice_body_size);
        rdv2_w64(idx + 12, (uint64_t)in->positions[first_read]);
        rdv2_w64(idx + 20, (uint64_t)in->positions[first_read + n_in_slice - 1]);
        rdv2_w32(idx + 28, (uint32_t)n_in_slice);

        cur += slice_body_size;
    }

    *out_len = cur;
    return 0;
}

/* ── Per-slice decoder ──────────────────────────────────────────── */

static int rdv2_decode_slice(
    const uint8_t  *body, size_t body_size,
    const int64_t  *positions, const char **cigar_strings,
    uint64_t        first_read, uint64_t n_reads_in_slice,
    const uint8_t  *reference, uint64_t reference_length,
    uint8_t        *out_sequences, uint64_t *out_offsets)
{
    if (body_size < RDV2_SLICE_SUBHDR) return TTIO_RANS_ERR_CORRUPT;
    uint32_t flag_len = rdv2_r32(body + 0);
    uint32_t bs_len   = rdv2_r32(body + 4);
    uint32_t in_len   = rdv2_r32(body + 8);
    uint32_t sc_len   = rdv2_r32(body + 12);
    uint32_t esc_len  = rdv2_r32(body + 16);
    uint32_t reserved = rdv2_r32(body + 20);
    if (reserved != 0) return TTIO_RANS_ERR_CORRUPT;
    if ((size_t)RDV2_SLICE_SUBHDR + flag_len + bs_len + in_len + sc_len + esc_len > body_size)
        return TTIO_RANS_ERR_CORRUPT;

    uint64_t total_match = 0, total_ins = 0, total_sc = 0;
    for (uint64_t r = 0; r < n_reads_in_slice; r++) {
        uint64_t m, ins, s;
        if (rdv2_parse_cigar_counts(cigar_strings[first_read + r], &m, &ins, &s) != 0)
            return TTIO_RANS_ERR_PARAM;
        total_match += m; total_ins += ins; total_sc += s;
    }

    const uint8_t *flag_in = body + RDV2_SLICE_SUBHDR;
    const uint8_t *bs_in   = flag_in + flag_len;
    const uint8_t *in_in   = bs_in + bs_len;
    const uint8_t *sc_in   = in_in + in_len;
    const uint8_t *esc_in  = sc_in + sc_len;

    uint8_t *flag_buf = malloc(total_match ? total_match : 1);
    uint8_t *bs_packed = malloc((total_match + 3) / 4 + 1);
    uint8_t *in_packed = malloc((total_ins + 3) / 4 + 1);
    uint8_t *sc_packed = malloc((total_sc + 3) / 4 + 1);
    uint8_t *esc_buf   = malloc((total_match + total_ins + total_sc) * 12 + 16);
    uint8_t *bs_codes = NULL, *in_codes = NULL, *sc_codes = NULL;
    int rc = 0;
    size_t flag_dec = 0, bs_dec = 0, in_dec = 0, sc_dec = 0, esc_dec = 0;

    if (!flag_buf || !bs_packed || !in_packed || !sc_packed || !esc_buf) {
        rc = TTIO_RANS_ERR_ALLOC; goto cleanup;
    }

    rc = ttio_rans_o0_decode(flag_in, flag_len, flag_buf, total_match ? total_match : 1, &flag_dec);
    if (rc) goto cleanup;
    if (flag_dec != total_match) { rc = TTIO_RANS_ERR_CORRUPT; goto cleanup; }

    rc = ttio_rans_o0_decode(bs_in, bs_len, bs_packed, (total_match + 3) / 4 + 1, &bs_dec);
    if (rc) goto cleanup;
    rc = ttio_rans_o0_decode(in_in, in_len, in_packed, (total_ins + 3) / 4 + 1, &in_dec);
    if (rc) goto cleanup;
    rc = ttio_rans_o0_decode(sc_in, sc_len, sc_packed, (total_sc + 3) / 4 + 1, &sc_dec);
    if (rc) goto cleanup;
    rc = ttio_rans_o0_decode(esc_in, esc_len, esc_buf, (total_match + total_ins + total_sc) * 12 + 16, &esc_dec);
    if (rc) goto cleanup;

    /* Count BS codes needed from flag (entries where flag=1) */
    uint64_t bs_n_codes = 0;
    for (uint64_t fi = 0; fi < total_match; fi++) if (flag_buf[fi]) bs_n_codes++;

    bs_codes = malloc(bs_n_codes ? bs_n_codes : 1);
    in_codes = malloc(total_ins ? total_ins : 1);
    sc_codes = malloc(total_sc ? total_sc : 1);
    if (!bs_codes || !in_codes || !sc_codes) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
    rdv2_unpack_2bit(bs_packed, bs_n_codes, bs_codes);
    rdv2_unpack_2bit(in_packed, total_ins, in_codes);
    rdv2_unpack_2bit(sc_packed, total_sc, sc_codes);

    /* Pre-read first ESC entry (if any) */
    size_t esc_off = 0;
    uint8_t  next_esc_stream  = 0xFF;
    uint64_t next_esc_index   = 0;
    uint8_t  next_esc_literal = 0;

#define CONSUME_NEXT_ESC() do { \
    if (esc_off < esc_dec) { \
        next_esc_stream = esc_buf[esc_off++]; \
        if (next_esc_stream > RDV2_ESC_SC) { rc = TTIO_RANS_ERR_RESERVED_ESC_STREAM; goto cleanup; } \
        size_t _consumed = 0; \
        if (rdv2_varint_decode(esc_buf + esc_off, esc_dec - esc_off, &next_esc_index, &_consumed) != 0) { \
            rc = TTIO_RANS_ERR_CORRUPT; goto cleanup; \
        } \
        esc_off += _consumed; \
        if (esc_off >= esc_dec) { rc = TTIO_RANS_ERR_CORRUPT; goto cleanup; } \
        next_esc_literal = esc_buf[esc_off++]; \
    } else { \
        next_esc_stream = 0xFF; \
    } \
} while (0)

    CONSUME_NEXT_ESC();

    /* Walk reads, reconstruct sequences */
    uint64_t flag_pos = 0, bs_pos = 0, in_pos = 0, sc_pos = 0;
    uint64_t write_pos = out_offsets[first_read];

    for (uint64_t r = 0; r < n_reads_in_slice; r++) {
        uint64_t gid = first_read + r;
        const char *cigar = cigar_strings[gid];
        int64_t ref_pos = positions[gid] - 1;  /* 1-based → 0-based */
        const char *p = cigar;
        while (*p) {
            uint64_t length = 0;
            while (*p >= '0' && *p <= '9') { length = length * 10 + (uint64_t)(*p - '0'); p++; }
            char op = *p++;
            switch (op) {
                case 'M': case '=': case 'X':
                    for (uint64_t k = 0; k < length; k++) {
                        if ((uint64_t)ref_pos >= reference_length) { rc = TTIO_RANS_ERR_PARAM; goto cleanup; }
                        uint8_t fb = reference[ref_pos];
                        if (fb >= 'a' && fb <= 'z') fb = (uint8_t)(fb - 32);
                        if (flag_buf[flag_pos] == 0) {
                            out_sequences[write_pos++] = fb;
                        } else {
                            uint8_t base;
                            if (next_esc_stream == RDV2_ESC_BS && next_esc_index == bs_pos) {
                                base = next_esc_literal;
                                CONSUME_NEXT_ESC();
                            } else {
                                base = rdv2_2bit_to_base(bs_codes[bs_pos]);
                            }
                            out_sequences[write_pos++] = base;
                            bs_pos++;
                        }
                        flag_pos++;
                        ref_pos++;
                    }
                    break;
                case 'I':
                    for (uint64_t k = 0; k < length; k++) {
                        uint8_t base;
                        if (next_esc_stream == RDV2_ESC_IN && next_esc_index == in_pos) {
                            base = next_esc_literal;
                            CONSUME_NEXT_ESC();
                        } else {
                            base = rdv2_2bit_to_base(in_codes[in_pos]);
                        }
                        out_sequences[write_pos++] = base;
                        in_pos++;
                    }
                    break;
                case 'S':
                    for (uint64_t k = 0; k < length; k++) {
                        uint8_t base;
                        if (next_esc_stream == RDV2_ESC_SC && next_esc_index == sc_pos) {
                            base = next_esc_literal;
                            CONSUME_NEXT_ESC();
                        } else {
                            base = rdv2_2bit_to_base(sc_codes[sc_pos]);
                        }
                        out_sequences[write_pos++] = base;
                        sc_pos++;
                    }
                    break;
                case 'D': case 'N': ref_pos += (int64_t)length; break;
                case 'H': case 'P': break;
                default: rc = TTIO_RANS_ERR_PARAM; goto cleanup;
            }
        }
        out_offsets[gid + 1] = write_pos;
    }
#undef CONSUME_NEXT_ESC

    /* I2: ESC fully consumed (I4 already enforced in CONSUME_NEXT_ESC) */
    if (esc_off != esc_dec || next_esc_stream != 0xFF) {
        rc = TTIO_RANS_ERR_ESC_LENGTH_MISMATCH; goto cleanup;
    }

cleanup:
    free(flag_buf); free(bs_packed); free(in_packed); free(sc_packed); free(esc_buf);
    free(bs_codes); free(in_codes); free(sc_codes);
    return rc;
}

/* ── Top-level decoder ──────────────────────────────────────────── */

int ttio_ref_diff_v2_decode(
    const uint8_t  *encoded, size_t encoded_size,
    const int64_t  *positions, const char **cigar_strings,
    uint64_t        n_reads,
    const uint8_t  *reference, uint64_t reference_length,
    uint8_t        *out_sequences, uint64_t *out_offsets)
{
    if (!encoded || !positions || !cigar_strings || !reference ||
        !out_sequences || !out_offsets) return TTIO_RANS_ERR_PARAM;
    if (encoded_size < RDV2_OUTER_FIXED) return TTIO_RANS_ERR_CORRUPT;
    if (memcmp(encoded, RDV2_MAGIC, 4) != 0) return TTIO_RANS_ERR_CORRUPT;
    if (encoded[4] != RDV2_VERSION) return TTIO_RANS_ERR_CORRUPT;
    uint32_t n_slices    = rdv2_r32(encoded + 8);
    uint64_t hdr_n_reads = rdv2_r64(encoded + 12);
    if (hdr_n_reads != n_reads) return TTIO_RANS_ERR_PARAM;
    uint16_t uri_len = rdv2_r16(encoded + 36);
    size_t header_len = RDV2_OUTER_FIXED + uri_len;
    if (encoded_size < header_len + (size_t)n_slices * RDV2_SLICE_INDEX_ENTRY)
        return TTIO_RANS_ERR_CORRUPT;
    size_t slice_bodies_off = header_len + (size_t)n_slices * RDV2_SLICE_INDEX_ENTRY;

    out_offsets[0] = 0;

    uint64_t first_read = 0;
    for (uint32_t s = 0; s < n_slices; s++) {
        const uint8_t *idx = encoded + header_len + s * RDV2_SLICE_INDEX_ENTRY;
        uint64_t body_off  = rdv2_r64(idx + 0);
        uint32_t body_len  = rdv2_r32(idx + 8);
        uint32_t num_reads = rdv2_r32(idx + 28);
        if (slice_bodies_off + body_off + body_len > encoded_size)
            return TTIO_RANS_ERR_CORRUPT;
        const uint8_t *body = encoded + slice_bodies_off + body_off;
        int rc = rdv2_decode_slice(body, body_len, positions, cigar_strings,
                                   first_read, num_reads,
                                   reference, reference_length,
                                   out_sequences, out_offsets);
        if (rc != 0) return rc;
        first_read += num_reads;
    }
    if (first_read != n_reads) return TTIO_RANS_ERR_CORRUPT;
    return 0;
}
