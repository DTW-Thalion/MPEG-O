/* NAME_TOKENIZED v2 codec implementation.
 * Spec: docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md
 *
 * Wire layout (big-endian magic, little-endian everything else):
 *   Container header:
 *     "NTK2" (4) | version=0x01 (1) | flags (1) | n_reads u32 LE (4)
 *     | n_blocks u16 LE (2) | block_offsets[u32 LE x n_blocks]
 *   Per-block:
 *     n_reads u32 LE (4) | body_len u32 LE (4) | body
 *   Body = 8 substreams in fixed order, each:
 *     body_len u32 LE (4) | mode u8 (1) | body bytes
 *   Modes: 0x00 raw, 0x01 rANS-O0.
 *   Substream order: FLAG, POOL_IDX, MATCH_K, COL_TYPES,
 *                    NUM_DELTA, DICT_CODE, DICT_LIT, VERB_LIT.
 */
#include "name_tok_v2.h"
#include "ttio_rans.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ──────── Tokenise + bit-pack + varint helpers (Task 2) ──────── */

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

/* ──────── Internal helpers: growable byte buffer ──────── */

typedef struct {
    uint8_t *data;
    size_t   len;
    size_t   cap;
    int      err;        /* 1 if allocation failed */
} ntv2_buf;

static void buf_init(ntv2_buf *b) {
    b->data = NULL; b->len = 0; b->cap = 0; b->err = 0;
}

static void buf_free(ntv2_buf *b) {
    free(b->data); b->data = NULL; b->len = 0; b->cap = 0;
}

static int buf_reserve(ntv2_buf *b, size_t need) {
    if (b->err) return -1;
    if (b->cap >= need) return 0;
    size_t nc = b->cap ? b->cap : 64;
    while (nc < need) nc *= 2;
    uint8_t *p = (uint8_t *)realloc(b->data, nc);
    if (!p) { b->err = 1; return -1; }
    b->data = p; b->cap = nc;
    return 0;
}

static int buf_append(ntv2_buf *b, const uint8_t *src, size_t n) {
    if (n == 0) return 0;
    if (buf_reserve(b, b->len + n) != 0) return -1;
    memcpy(b->data + b->len, src, n);
    b->len += n;
    return 0;
}

static int buf_append_u8(ntv2_buf *b, uint8_t v) {
    return buf_append(b, &v, 1);
}

static int buf_append_uvarint(ntv2_buf *b, uint64_t v) {
    uint8_t tmp[10];
    size_t n = ntv2_uvarint_encode(v, tmp);
    return buf_append(b, tmp, n);
}

static int buf_append_svarint(ntv2_buf *b, int64_t v) {
    uint8_t tmp[10];
    size_t n = ntv2_svarint_encode(v, tmp);
    return buf_append(b, tmp, n);
}

static void write_u32_le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static uint32_t read_u32_le(const uint8_t *p) {
    return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

static void write_u16_le(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
}

static uint16_t read_u16_le(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

/* ──────── Per-block encoder state ──────── */

#define NTV2_MAX_TOKENS 255

typedef struct {
    /* Tokenisation result for one name, plus a copy of the name bytes
     * so token slices remain valid after the source name is dropped. */
    char    *name;
    size_t   name_len;
    uint8_t  n_tokens;
    uint8_t  types[NTV2_MAX_TOKENS];
    uint16_t starts[NTV2_MAX_TOKENS];
    uint16_t lens[NTV2_MAX_TOKENS];
    uint64_t nums[NTV2_MAX_TOKENS];
} ntv2_pool_entry;

static void pool_entry_clear(ntv2_pool_entry *e) {
    free(e->name);
    e->name = NULL;
    e->name_len = 0;
    e->n_tokens = 0;
}

/* Per-column dictionary entry.  We keep an array of literals (in
 * insertion order); code = index. Lookup is linear (per-column dict
 * stays small in a 4096-row block — bounded by distinct strings). */
typedef struct {
    char   **lits;       /* lits[code] = malloc'd byte block (not NUL-terminated) */
    size_t  *lit_lens;
    size_t   n;
    size_t   cap;
} ntv2_col_dict;

static void col_dict_init(ntv2_col_dict *d) {
    d->lits = NULL; d->lit_lens = NULL; d->n = 0; d->cap = 0;
}

static void col_dict_free(ntv2_col_dict *d) {
    for (size_t i = 0; i < d->n; i++) free(d->lits[i]);
    free(d->lits);
    free(d->lit_lens);
    d->lits = NULL; d->lit_lens = NULL; d->n = 0; d->cap = 0;
}

static int col_dict_lookup(const ntv2_col_dict *d,
                           const char *s, size_t slen, uint64_t *out_code) {
    for (size_t i = 0; i < d->n; i++) {
        if (d->lit_lens[i] == slen && memcmp(d->lits[i], s, slen) == 0) {
            *out_code = (uint64_t)i;
            return 1;
        }
    }
    return 0;
}

static int col_dict_add(ntv2_col_dict *d, const char *s, size_t slen) {
    if (d->n >= d->cap) {
        size_t nc = d->cap ? d->cap * 2 : 8;
        char **nl = (char **)realloc(d->lits, nc * sizeof(*nl));
        if (!nl) return -1;
        d->lits = nl;
        size_t *nll = (size_t *)realloc(d->lit_lens, nc * sizeof(*nll));
        if (!nll) return -1;
        d->lit_lens = nll;
        d->cap = nc;
    }
    char *copy = (char *)malloc(slen > 0 ? slen : 1);
    if (!copy) return -1;
    if (slen > 0) memcpy(copy, s, slen);
    d->lits[d->n] = copy;
    d->lit_lens[d->n] = slen;
    d->n++;
    return 0;
}

static int names_equal(const ntv2_pool_entry *e, const char *name, size_t name_len) {
    return e->name_len == name_len && memcmp(e->name, name, name_len) == 0;
}

/* ──────── Substream wrap: choose raw vs rANS-O0 (smaller wins) ──────── */

/* Append one substream's framing to `out`. body[body_len] is the raw
 * uncompressed payload.  Tries rANS-O0; emits whichever is smaller.
 * Tie → raw (mode 0x00). */
static int append_substream(ntv2_buf *out,
                            const uint8_t *body, size_t body_len) {
    int use_rans = 0;
    uint8_t *rans_buf = NULL;
    size_t   rans_len = 0;
    if (body_len > 16) {
        size_t rcap = ttio_rans_o0_max_encoded_size(body_len);
        rans_buf = (uint8_t *)malloc(rcap);
        if (!rans_buf) return -1;
        size_t rl = rcap;
        int rc = ttio_rans_o0_encode(body, body_len, rans_buf, &rl);
        if (rc == 0 && rl < body_len) {
            use_rans = 1;
            rans_len = rl;
        }
    }

    uint8_t hdr[5];
    if (use_rans) {
        write_u32_le(hdr, (uint32_t)rans_len);
        hdr[4] = NTV2_MODE_RANS_O0;
        if (buf_append(out, hdr, 5) != 0) { free(rans_buf); return -1; }
        if (buf_append(out, rans_buf, rans_len) != 0) { free(rans_buf); return -1; }
    } else {
        write_u32_le(hdr, (uint32_t)body_len);
        hdr[4] = NTV2_MODE_RAW;
        if (buf_append(out, hdr, 5) != 0) { free(rans_buf); return -1; }
        if (body_len > 0 && buf_append(out, body, body_len) != 0) {
            free(rans_buf); return -1;
        }
    }
    free(rans_buf);
    return 0;
}

/* ──────── Encode one block ──────── */

/* Encode `n_block` names starting at `names_start`.  Appends the
 * complete per-block frame (n_reads u32 LE | body_len u32 LE | body)
 * to `block_out`. */
static int encode_block(const char * const *names_start,
                        size_t n_block,
                        ntv2_buf *block_out) {
    int rc = TTIO_RANS_OK;

    /* Tokenise all rows up-front. */
    ntv2_pool_entry *rows = (ntv2_pool_entry *)calloc(n_block, sizeof(*rows));
    if (!rows) return TTIO_RANS_ERR_ALLOC;
    for (size_t i = 0; i < n_block; i++) {
        const char *src = names_start[i];
        if (src == NULL) { rc = TTIO_RANS_ERR_PARAM; goto cleanup_rows; }
        size_t L = strlen(src);
        rows[i].name = (char *)malloc(L > 0 ? L : 1);
        if (!rows[i].name) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup_rows; }
        if (L > 0) memcpy(rows[i].name, src, L);
        rows[i].name_len = L;
        if (ntv2_tokenise(src, rows[i].types, rows[i].starts, rows[i].lens,
                          &rows[i].n_tokens, rows[i].nums) != 0) {
            rc = TTIO_RANS_ERR_PARAM;
            goto cleanup_rows;
        }
    }

    /* Pool — FIFO of up to 8 entries. */
    ntv2_pool_entry pool[NTV2_POOL_SIZE];
    memset(pool, 0, sizeof(pool));
    uint8_t pool_len = 0;

    /* Block COL_TYPES — set on first COL/MATCH-K row. */
    int      block_has_cols = 0;
    uint8_t  block_n_cols = 0;
    uint8_t  block_col_types[NTV2_MAX_TOKENS];

    /* Per-column delta state for numeric cols. */
    int      col_num_seen[NTV2_MAX_TOKENS];
    uint64_t col_num_prev[NTV2_MAX_TOKENS];
    memset(col_num_seen, 0, sizeof(col_num_seen));
    memset(col_num_prev, 0, sizeof(col_num_prev));

    /* Per-column dictionary state for string cols. */
    ntv2_col_dict col_dict[NTV2_MAX_TOKENS];
    for (int j = 0; j < NTV2_MAX_TOKENS; j++) col_dict_init(&col_dict[j]);

    /* Substream raw bodies (uncompressed bytes accumulated row-by-row). */
    ntv2_buf flag_vals;     buf_init(&flag_vals);
    ntv2_buf pool_idx_vals; buf_init(&pool_idx_vals);
    ntv2_buf match_k_buf;   buf_init(&match_k_buf);
    ntv2_buf num_delta_buf; buf_init(&num_delta_buf);
    ntv2_buf dict_code_buf; buf_init(&dict_code_buf);
    ntv2_buf dict_lit_buf;  buf_init(&dict_lit_buf);
    ntv2_buf verb_lit_buf;  buf_init(&verb_lit_buf);
    ntv2_buf col_types_buf; buf_init(&col_types_buf);
    ntv2_buf flag_packed;     buf_init(&flag_packed);
    ntv2_buf pool_idx_packed; buf_init(&pool_idx_packed);
    ntv2_buf body;            buf_init(&body);

    /* Encode each row. */
    for (size_t i = 0; i < n_block; i++) {
        const ntv2_pool_entry *r = &rows[i];

        /* 1. DUP — first byte-equal pool entry (smallest pool_idx). */
        int dup_idx = -1;
        for (uint8_t k = 0; k < pool_len; k++) {
            if (names_equal(&pool[k], r->name, r->name_len)) {
                dup_idx = k; break;
            }
        }

        /* 2. MATCH-K — only legal if row's col-shape matches block's
         *    AND pool entry's first K cols match the block's first K
         *    col types (and values). */
        int match_idx = -1;
        uint8_t match_k = 0;
        int row_compatible = 0;
        if (dup_idx < 0) {
            if (block_has_cols && r->n_tokens == block_n_cols) {
                row_compatible = 1;
                for (uint8_t j = 0; j < block_n_cols; j++) {
                    int rt = (r->types[j] == NTV2_TOK_NUM) ? 0 : 1;
                    if (rt != block_col_types[j]) { row_compatible = 0; break; }
                }
            }
            if (row_compatible) {
                for (uint8_t k = 0; k < pool_len; k++) {
                    const ntv2_pool_entry *p = &pool[k];
                    if (p->n_tokens == 0) continue;
                    uint8_t maxk = p->n_tokens < r->n_tokens
                                 ? p->n_tokens : r->n_tokens;
                    uint8_t kk = 0;
                    for (uint8_t j = 0; j < maxk; j++) {
                        int pt = (p->types[j] == NTV2_TOK_NUM) ? 0 : 1;
                        if (pt != block_col_types[j]) break;
                        if (p->types[j] != r->types[j]) break;
                        if (p->types[j] == NTV2_TOK_NUM) {
                            if (p->nums[j] != r->nums[j]) break;
                        } else {
                            if (p->lens[j] != r->lens[j]) break;
                            if (memcmp(p->name + p->starts[j],
                                       r->name + r->starts[j],
                                       p->lens[j]) != 0) break;
                        }
                        kk++;
                    }
                    /* Strict prefix: 0 < kk < r->n_tokens. */
                    if (kk > 0 && kk < r->n_tokens && kk > match_k) {
                        match_k = kk;
                        match_idx = k;
                    }
                }
            }
        }

        /* 3. COL — if compatible (or block has no shape yet, set it). */
        int can_col = 0;
        if (dup_idx < 0 && match_idx < 0 && r->n_tokens > 0) {
            if (!block_has_cols) {
                can_col = 1;
            } else if (r->n_tokens == block_n_cols) {
                int ok = 1;
                for (uint8_t j = 0; j < block_n_cols; j++) {
                    int rt = (r->types[j] == NTV2_TOK_NUM) ? 0 : 1;
                    if (rt != block_col_types[j]) { ok = 0; break; }
                }
                if (ok) can_col = 1;
            }
        }

        if (dup_idx >= 0) {
            if (buf_append_u8(&flag_vals, NTV2_FLAG_DUP) != 0) goto err_alloc;
            if (buf_append_u8(&pool_idx_vals, (uint8_t)dup_idx) != 0) goto err_alloc;
        } else if (match_idx >= 0) {
            if (buf_append_u8(&flag_vals, NTV2_FLAG_MATCH) != 0) goto err_alloc;
            if (buf_append_u8(&pool_idx_vals, (uint8_t)match_idx) != 0) goto err_alloc;
            if (buf_append_uvarint(&match_k_buf, (uint64_t)match_k) != 0) goto err_alloc;
            /* Update num_prev for matched cols [0, K) using pool entry. */
            const ntv2_pool_entry *p = &pool[match_idx];
            for (uint8_t j = 0; j < match_k; j++) {
                if (block_col_types[j] == 0) {  /* numeric */
                    col_num_prev[j] = p->nums[j];
                    col_num_seen[j] = 1;
                }
            }
            /* Emit suffix tokens [K, n_cols) — row-major. */
            for (uint8_t j = match_k; j < block_n_cols; j++) {
                if (block_col_types[j] == 0) {
                    if (!col_num_seen[j]) {
                        if (buf_append_uvarint(&num_delta_buf, r->nums[j]) != 0) goto err_alloc;
                        col_num_seen[j] = 1;
                    } else {
                        int64_t delta = (int64_t)(r->nums[j] - col_num_prev[j]);
                        if (buf_append_svarint(&num_delta_buf, delta) != 0) goto err_alloc;
                    }
                    col_num_prev[j] = r->nums[j];
                } else {
                    const char *sp = r->name + r->starts[j];
                    size_t slen = r->lens[j];
                    uint64_t code;
                    if (col_dict_lookup(&col_dict[j], sp, slen, &code)) {
                        if (buf_append_uvarint(&dict_code_buf, code) != 0) goto err_alloc;
                    } else {
                        code = (uint64_t)col_dict[j].n;
                        if (buf_append_uvarint(&dict_code_buf, code) != 0) goto err_alloc;
                        if (col_dict_add(&col_dict[j], sp, slen) != 0) goto err_alloc;
                        if (buf_append_uvarint(&dict_lit_buf, (uint64_t)slen) != 0) goto err_alloc;
                        if (buf_append(&dict_lit_buf, (const uint8_t *)sp, slen) != 0) goto err_alloc;
                    }
                }
            }
        } else if (can_col) {
            if (buf_append_u8(&flag_vals, NTV2_FLAG_COL) != 0) goto err_alloc;
            if (!block_has_cols) {
                block_has_cols = 1;
                block_n_cols = r->n_tokens;
                for (uint8_t j = 0; j < r->n_tokens; j++) {
                    block_col_types[j] = (r->types[j] == NTV2_TOK_NUM) ? 0 : 1;
                }
            }
            for (uint8_t j = 0; j < block_n_cols; j++) {
                if (block_col_types[j] == 0) {
                    if (!col_num_seen[j]) {
                        if (buf_append_uvarint(&num_delta_buf, r->nums[j]) != 0) goto err_alloc;
                        col_num_seen[j] = 1;
                    } else {
                        int64_t delta = (int64_t)(r->nums[j] - col_num_prev[j]);
                        if (buf_append_svarint(&num_delta_buf, delta) != 0) goto err_alloc;
                    }
                    col_num_prev[j] = r->nums[j];
                } else {
                    const char *sp = r->name + r->starts[j];
                    size_t slen = r->lens[j];
                    uint64_t code;
                    if (col_dict_lookup(&col_dict[j], sp, slen, &code)) {
                        if (buf_append_uvarint(&dict_code_buf, code) != 0) goto err_alloc;
                    } else {
                        code = (uint64_t)col_dict[j].n;
                        if (buf_append_uvarint(&dict_code_buf, code) != 0) goto err_alloc;
                        if (col_dict_add(&col_dict[j], sp, slen) != 0) goto err_alloc;
                        if (buf_append_uvarint(&dict_lit_buf, (uint64_t)slen) != 0) goto err_alloc;
                        if (buf_append(&dict_lit_buf, (const uint8_t *)sp, slen) != 0) goto err_alloc;
                    }
                }
            }
        } else {
            /* VERB */
            if (buf_append_u8(&flag_vals, NTV2_FLAG_VERB) != 0) goto err_alloc;
            if (buf_append_uvarint(&verb_lit_buf, (uint64_t)r->name_len) != 0) goto err_alloc;
            if (buf_append(&verb_lit_buf, (const uint8_t *)r->name, r->name_len) != 0) goto err_alloc;
        }

        /* Push to pool — copy this row's tokenisation into a fresh
         * pool entry.  Evict oldest if pool full. */
        if (pool_len == NTV2_POOL_SIZE) {
            pool_entry_clear(&pool[0]);
            for (uint8_t k = 1; k < NTV2_POOL_SIZE; k++) {
                pool[k - 1] = pool[k];
            }
            memset(&pool[NTV2_POOL_SIZE - 1], 0, sizeof(pool[0]));
            pool_len--;
        }
        ntv2_pool_entry *slot = &pool[pool_len];
        slot->name = (char *)malloc(r->name_len > 0 ? r->name_len : 1);
        if (!slot->name) goto err_alloc;
        if (r->name_len > 0) memcpy(slot->name, r->name, r->name_len);
        slot->name_len = r->name_len;
        slot->n_tokens = r->n_tokens;
        memcpy(slot->types, r->types, r->n_tokens);
        memcpy(slot->starts, r->starts, sizeof(uint16_t) * r->n_tokens);
        memcpy(slot->lens, r->lens, sizeof(uint16_t) * r->n_tokens);
        memcpy(slot->nums, r->nums, sizeof(uint64_t) * r->n_tokens);
        pool_len++;
    }

    /* Build COL_TYPES substream body. */
    if (block_has_cols) {
        if (buf_append_u8(&col_types_buf, block_n_cols) != 0) goto err_alloc;
        size_t bm_len = (block_n_cols + 7) / 8;
        uint8_t bm[32];  /* 255/8 + 1 = 32 */
        memset(bm, 0, bm_len);
        for (uint8_t j = 0; j < block_n_cols; j++) {
            if (block_col_types[j] == 1) {
                size_t bi = j / 8;
                int sh = 7 - (j % 8);
                bm[bi] |= (uint8_t)(1u << sh);
            }
        }
        if (buf_append(&col_types_buf, bm, bm_len) != 0) goto err_alloc;
    }

    /* Pack FLAG / POOL_IDX from raw 0..3 / 0..7 byte arrays. */
    if (flag_vals.len > 0) {
        size_t nb = (flag_vals.len * 2 + 7) / 8;
        if (buf_reserve(&flag_packed, nb) != 0) goto err_alloc;
        ntv2_pack_2bits(flag_vals.data, flag_vals.len, flag_packed.data);
        flag_packed.len = nb;
    }
    if (pool_idx_vals.len > 0) {
        size_t nb = (pool_idx_vals.len * 3 + 7) / 8;
        if (buf_reserve(&pool_idx_packed, nb) != 0) goto err_alloc;
        ntv2_pack_3bits(pool_idx_vals.data, pool_idx_vals.len, pool_idx_packed.data);
        pool_idx_packed.len = nb;
    }

    /* Compose body: 8 substreams in fixed order. */
    if (append_substream(&body, flag_packed.data,     flag_packed.len)     != 0) goto err_alloc;
    if (append_substream(&body, pool_idx_packed.data, pool_idx_packed.len) != 0) goto err_alloc;
    if (append_substream(&body, match_k_buf.data,     match_k_buf.len)     != 0) goto err_alloc;
    if (append_substream(&body, col_types_buf.data,   col_types_buf.len)   != 0) goto err_alloc;
    if (append_substream(&body, num_delta_buf.data,   num_delta_buf.len)   != 0) goto err_alloc;
    if (append_substream(&body, dict_code_buf.data,   dict_code_buf.len)   != 0) goto err_alloc;
    if (append_substream(&body, dict_lit_buf.data,    dict_lit_buf.len)    != 0) goto err_alloc;
    if (append_substream(&body, verb_lit_buf.data,    verb_lit_buf.len)    != 0) goto err_alloc;

    /* Emit per-block frame: n_reads u32 LE | body_len u32 LE | body. */
    {
        uint8_t hdr[8];
        write_u32_le(hdr, (uint32_t)n_block);
        write_u32_le(hdr + 4, (uint32_t)body.len);
        if (buf_append(block_out, hdr, 8) != 0) goto err_alloc;
        if (buf_append(block_out, body.data, body.len) != 0) goto err_alloc;
    }
    goto cleanup_full;

err_alloc:
    rc = TTIO_RANS_ERR_ALLOC;

cleanup_full:
    buf_free(&flag_vals);
    buf_free(&pool_idx_vals);
    buf_free(&match_k_buf);
    buf_free(&num_delta_buf);
    buf_free(&dict_code_buf);
    buf_free(&dict_lit_buf);
    buf_free(&verb_lit_buf);
    buf_free(&col_types_buf);
    buf_free(&flag_packed);
    buf_free(&pool_idx_packed);
    buf_free(&body);
    for (uint8_t k = 0; k < pool_len; k++) pool_entry_clear(&pool[k]);
    for (int j = 0; j < NTV2_MAX_TOKENS; j++) col_dict_free(&col_dict[j]);

cleanup_rows:
    for (size_t i = 0; i < n_block; i++) free(rows[i].name);
    free(rows);
    return rc;
}

/* ──────── Decode helpers ──────── */

/* Substream view (after any rANS-O0 decompression). */
typedef struct {
    uint8_t *data;        /* malloc'd if mode was rans, else points into input */
    size_t   len;
    int      owned;       /* 1 if data is malloc'd here */
} ntv2_sub;

static void sub_free(ntv2_sub *s) {
    if (s->owned) free(s->data);
    s->data = NULL; s->len = 0; s->owned = 0;
}

/* Parse one substream framing from input at *pos and produce an
 * uncompressed view.  Advances *pos. */
static int parse_substream(const uint8_t *body, size_t body_len,
                           size_t *pos, ntv2_sub *out) {
    if (*pos + 5 > body_len) return TTIO_RANS_ERR_CORRUPT;
    uint32_t slen = read_u32_le(body + *pos);
    uint8_t mode = body[*pos + 4];
    *pos += 5;
    if (*pos + slen > body_len) return TTIO_RANS_ERR_CORRUPT;
    if (mode != NTV2_MODE_RAW && mode != NTV2_MODE_RANS_O0) {
        return TTIO_RANS_ERR_CORRUPT;
    }
    if (mode == NTV2_MODE_RAW) {
        out->data = (uint8_t *)(body + *pos);  /* not owned */
        out->len = slen;
        out->owned = 0;
    } else {
        if (slen < 9) return TTIO_RANS_ERR_CORRUPT;
        const uint8_t *p = body + *pos;
        /* rANS-O0 wire: byte 0 order, bytes 1..4 orig_len BE. */
        uint32_t orig_len = ((uint32_t)p[1] << 24) | ((uint32_t)p[2] << 16)
                          | ((uint32_t)p[3] << 8)  |  (uint32_t)p[4];
        if (orig_len == 0) {
            out->data = NULL;
            out->len = 0;
            out->owned = 0;
        } else {
            uint8_t *buf = (uint8_t *)malloc(orig_len);
            if (!buf) return TTIO_RANS_ERR_ALLOC;
            size_t outlen = 0;
            int rc = ttio_rans_o0_decode(p, slen, buf, orig_len, &outlen);
            if (rc != 0 || outlen != orig_len) {
                free(buf); return TTIO_RANS_ERR_CORRUPT;
            }
            out->data = buf;
            out->len = orig_len;
            out->owned = 1;
        }
    }
    *pos += slen;
    return 0;
}

/* Decode one block.  Reads `block_body` (n_reads + body_len + body),
 * writes block_n_reads decoded names (each malloc'd C-string) into
 * `names` starting at *names_idx; advances *names_idx. */
static int decode_block(const uint8_t *block_body, size_t block_body_size,
                        char **names, uint64_t *names_idx, uint64_t names_cap) {
    int rc = TTIO_RANS_OK;
    ntv2_sub subs[NTV2_SUB_COUNT];
    for (int s = 0; s < NTV2_SUB_COUNT; s++) {
        subs[s].data = NULL; subs[s].len = 0; subs[s].owned = 0;
    }
    uint8_t *flags = NULL;
    uint8_t *pool_idxs = NULL;
    uint32_t *match_ks = NULL;
    ntv2_pool_entry pool[NTV2_POOL_SIZE];
    memset(pool, 0, sizeof(pool));
    uint8_t pool_len = 0;
    ntv2_col_dict col_dict[NTV2_MAX_TOKENS];
    for (int j = 0; j < NTV2_MAX_TOKENS; j++) col_dict_init(&col_dict[j]);

    if (block_body_size < 8) { rc = TTIO_RANS_ERR_CORRUPT; goto out; }
    uint32_t block_n_reads = read_u32_le(block_body);
    uint32_t body_len = read_u32_le(block_body + 4);
    if (block_n_reads == 0 || block_n_reads > NTV2_BLOCK_SIZE) {
        rc = TTIO_RANS_ERR_CORRUPT; goto out;
    }
    if ((size_t)8 + (size_t)body_len > block_body_size) {
        rc = TTIO_RANS_ERR_CORRUPT; goto out;
    }
    if (*names_idx + (uint64_t)block_n_reads > names_cap) {
        rc = TTIO_RANS_ERR_CORRUPT; goto out;
    }

    const uint8_t *body = block_body + 8;
    size_t pos = 0;
    for (int s = 0; s < NTV2_SUB_COUNT; s++) {
        rc = parse_substream(body, body_len, &pos, &subs[s]);
        if (rc != 0) goto out;
    }
    if (pos != body_len) { rc = TTIO_RANS_ERR_CORRUPT; goto out; }

    /* Unpack FLAG (2-bit per row). */
    flags = (uint8_t *)malloc(block_n_reads);
    if (!flags) { rc = TTIO_RANS_ERR_ALLOC; goto out; }
    {
        size_t need = (block_n_reads * 2 + 7) / 8;
        if (subs[NTV2_SUB_FLAG].len < need) { rc = TTIO_RANS_ERR_CORRUPT; goto out; }
        ntv2_unpack_2bits(subs[NTV2_SUB_FLAG].data, block_n_reads, flags);
    }
    for (uint32_t r = 0; r < block_n_reads; r++) {
        if (flags[r] > 3) { rc = TTIO_RANS_ERR_NTV2_BAD_FLAG; goto out; }
    }

    /* Count DUP/MATCH and MATCH rows. */
    uint32_t n_pool = 0, n_match = 0;
    for (uint32_t r = 0; r < block_n_reads; r++) {
        uint8_t f = flags[r];
        if (f == NTV2_FLAG_DUP || f == NTV2_FLAG_MATCH) n_pool++;
        if (f == NTV2_FLAG_MATCH) n_match++;
    }

    if (n_pool > 0) {
        pool_idxs = (uint8_t *)malloc(n_pool);
        if (!pool_idxs) { rc = TTIO_RANS_ERR_ALLOC; goto out; }
        size_t need = (n_pool * 3 + 7) / 8;
        if (subs[NTV2_SUB_POOL_IDX].len < need) { rc = TTIO_RANS_ERR_CORRUPT; goto out; }
        ntv2_unpack_3bits(subs[NTV2_SUB_POOL_IDX].data, n_pool, pool_idxs);
    }

    if (n_match > 0) {
        match_ks = (uint32_t *)malloc(n_match * sizeof(uint32_t));
        if (!match_ks) { rc = TTIO_RANS_ERR_ALLOC; goto out; }
        size_t mp = 0;
        for (uint32_t i = 0; i < n_match; i++) {
            if (mp >= subs[NTV2_SUB_MATCH_K].len) {
                rc = TTIO_RANS_ERR_CORRUPT; goto out;
            }
            uint64_t v;
            size_t adv = ntv2_uvarint_decode(subs[NTV2_SUB_MATCH_K].data + mp, &v);
            if (adv == 0 || mp + adv > subs[NTV2_SUB_MATCH_K].len || v > NTV2_MAX_TOKENS) {
                rc = TTIO_RANS_ERR_CORRUPT; goto out;
            }
            match_ks[i] = (uint32_t)v;
            mp += adv;
        }
        if (mp != subs[NTV2_SUB_MATCH_K].len) {
            rc = TTIO_RANS_ERR_CORRUPT; goto out;
        }
    } else if (subs[NTV2_SUB_MATCH_K].len != 0) {
        rc = TTIO_RANS_ERR_CORRUPT; goto out;
    }

    /* Parse COL_TYPES. */
    int       block_has_cols = 0;
    uint8_t   block_n_cols = 0;
    uint8_t   block_col_types[NTV2_MAX_TOKENS];
    if (subs[NTV2_SUB_COL_TYPES].len > 0) {
        block_n_cols = subs[NTV2_SUB_COL_TYPES].data[0];
        if (block_n_cols == 0) { rc = TTIO_RANS_ERR_CORRUPT; goto out; }
        size_t bm_len = (block_n_cols + 7) / 8;
        if (subs[NTV2_SUB_COL_TYPES].len != 1 + bm_len) {
            rc = TTIO_RANS_ERR_CORRUPT; goto out;
        }
        const uint8_t *bm = subs[NTV2_SUB_COL_TYPES].data + 1;
        for (uint8_t j = 0; j < block_n_cols; j++) {
            size_t bi = j / 8;
            int sh = 7 - (j % 8);
            block_col_types[j] = (uint8_t)((bm[bi] >> sh) & 1);
        }
        block_has_cols = 1;
    }

    /* Per-column delta state. */
    int      col_num_seen[NTV2_MAX_TOKENS];
    uint64_t col_num_prev[NTV2_MAX_TOKENS];
    memset(col_num_seen, 0, sizeof(col_num_seen));
    memset(col_num_prev, 0, sizeof(col_num_prev));

    /* Substream cursors. */
    size_t nd_pos = 0, dc_pos = 0, dl_pos = 0, vl_pos = 0;
    uint32_t pool_iter = 0, match_iter = 0;

    /* Per-row decode. */
    for (uint32_t r = 0; r < block_n_reads; r++) {
        uint8_t flag = flags[r];
        char *out_name = NULL;
        size_t out_name_len = 0;
        ntv2_buf name_buf;
        buf_init(&name_buf);

        if (flag == NTV2_FLAG_DUP) {
            uint8_t pi = pool_idxs[pool_iter++];
            if (pi >= pool_len) { rc = TTIO_RANS_ERR_NTV2_POOL_OOB; goto out; }
            out_name_len = pool[pi].name_len;
            out_name = (char *)malloc(out_name_len + 1);
            if (!out_name) { rc = TTIO_RANS_ERR_ALLOC; goto out; }
            if (out_name_len > 0) memcpy(out_name, pool[pi].name, out_name_len);
            out_name[out_name_len] = '\0';
        } else if (flag == NTV2_FLAG_MATCH) {
            uint8_t pi = pool_idxs[pool_iter++];
            uint32_t K = match_ks[match_iter++];
            if (pi >= pool_len) { rc = TTIO_RANS_ERR_NTV2_POOL_OOB; goto out; }
            if (!block_has_cols) { rc = TTIO_RANS_ERR_CORRUPT; goto out; }
            const ntv2_pool_entry *pe = &pool[pi];
            if (pe->n_tokens != block_n_cols) {
                rc = TTIO_RANS_ERR_CORRUPT; goto out;
            }
            if (K == 0 || K >= pe->n_tokens) {
                rc = TTIO_RANS_ERR_NTV2_BAD_K; goto out;
            }
            for (uint32_t j = 0; j < K; j++) {
                int pt = (pe->types[j] == NTV2_TOK_NUM) ? 0 : 1;
                if (pt != block_col_types[j]) {
                    rc = TTIO_RANS_ERR_CORRUPT; goto out;
                }
            }
            for (uint32_t j = 0; j < K; j++) {
                if (block_col_types[j] == 0) {
                    col_num_prev[j] = pe->nums[j];
                    col_num_seen[j] = 1;
                }
            }
            /* Build name = pool prefix tokens [0, K) + decoded suffix [K, n_cols). */
            for (uint32_t j = 0; j < K; j++) {
                if (pe->types[j] == NTV2_TOK_NUM) {
                    char tmp[32];
                    int tn = snprintf(tmp, sizeof(tmp), "%llu",
                                      (unsigned long long)pe->nums[j]);
                    if (buf_append(&name_buf, (const uint8_t *)tmp, (size_t)tn) != 0) {
                        buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                    }
                } else {
                    if (buf_append(&name_buf,
                                   (const uint8_t *)(pe->name + pe->starts[j]),
                                   pe->lens[j]) != 0) {
                        buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                    }
                }
            }
            for (uint32_t j = K; j < block_n_cols; j++) {
                uint8_t ctype = block_col_types[j];
                if (ctype == 0) {
                    uint64_t v;
                    if (!col_num_seen[j]) {
                        if (nd_pos >= subs[NTV2_SUB_NUM_DELTA].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        size_t adv = ntv2_uvarint_decode(
                            subs[NTV2_SUB_NUM_DELTA].data + nd_pos, &v);
                        if (adv == 0 || nd_pos + adv > subs[NTV2_SUB_NUM_DELTA].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        nd_pos += adv;
                        col_num_seen[j] = 1;
                        col_num_prev[j] = v;
                    } else {
                        if (nd_pos >= subs[NTV2_SUB_NUM_DELTA].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        int64_t d;
                        size_t adv = ntv2_svarint_decode(
                            subs[NTV2_SUB_NUM_DELTA].data + nd_pos, &d);
                        if (adv == 0 || nd_pos + adv > subs[NTV2_SUB_NUM_DELTA].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        nd_pos += adv;
                        v = col_num_prev[j] + (uint64_t)d;
                        col_num_prev[j] = v;
                    }
                    char tmp[32];
                    int tn = snprintf(tmp, sizeof(tmp), "%llu",
                                      (unsigned long long)v);
                    if (buf_append(&name_buf, (const uint8_t *)tmp, (size_t)tn) != 0) {
                        buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                    }
                } else {
                    if (dc_pos >= subs[NTV2_SUB_DICT_CODE].len) {
                        buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                    }
                    uint64_t code;
                    size_t adv = ntv2_uvarint_decode(
                        subs[NTV2_SUB_DICT_CODE].data + dc_pos, &code);
                    if (adv == 0 || dc_pos + adv > subs[NTV2_SUB_DICT_CODE].len) {
                        buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                    }
                    dc_pos += adv;
                    ntv2_col_dict *d = &col_dict[j];
                    if (code < d->n) {
                        if (buf_append(&name_buf,
                                       (const uint8_t *)d->lits[code],
                                       d->lit_lens[code]) != 0) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                        }
                    } else if (code == d->n) {
                        if (dl_pos >= subs[NTV2_SUB_DICT_LIT].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        uint64_t lit_len;
                        adv = ntv2_uvarint_decode(
                            subs[NTV2_SUB_DICT_LIT].data + dl_pos, &lit_len);
                        if (adv == 0 || dl_pos + adv > subs[NTV2_SUB_DICT_LIT].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        dl_pos += adv;
                        if (dl_pos + lit_len > subs[NTV2_SUB_DICT_LIT].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        if (col_dict_add(d,
                                         (const char *)(subs[NTV2_SUB_DICT_LIT].data + dl_pos),
                                         (size_t)lit_len) != 0) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                        }
                        if (buf_append(&name_buf,
                                       subs[NTV2_SUB_DICT_LIT].data + dl_pos,
                                       (size_t)lit_len) != 0) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                        }
                        dl_pos += (size_t)lit_len;
                    } else {
                        buf_free(&name_buf);
                        rc = TTIO_RANS_ERR_NTV2_DICT_OVERFLOW; goto out;
                    }
                }
            }
            out_name_len = name_buf.len;
            out_name = (char *)malloc(out_name_len + 1);
            if (!out_name) {
                buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
            }
            if (out_name_len > 0) memcpy(out_name, name_buf.data, out_name_len);
            out_name[out_name_len] = '\0';
            buf_free(&name_buf);
        } else if (flag == NTV2_FLAG_COL) {
            if (!block_has_cols) { rc = TTIO_RANS_ERR_CORRUPT; goto out; }
            for (uint8_t j = 0; j < block_n_cols; j++) {
                uint8_t ctype = block_col_types[j];
                if (ctype == 0) {
                    uint64_t v;
                    if (!col_num_seen[j]) {
                        if (nd_pos >= subs[NTV2_SUB_NUM_DELTA].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        size_t adv = ntv2_uvarint_decode(
                            subs[NTV2_SUB_NUM_DELTA].data + nd_pos, &v);
                        if (adv == 0 || nd_pos + adv > subs[NTV2_SUB_NUM_DELTA].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        nd_pos += adv;
                        col_num_seen[j] = 1;
                        col_num_prev[j] = v;
                    } else {
                        if (nd_pos >= subs[NTV2_SUB_NUM_DELTA].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        int64_t d;
                        size_t adv = ntv2_svarint_decode(
                            subs[NTV2_SUB_NUM_DELTA].data + nd_pos, &d);
                        if (adv == 0 || nd_pos + adv > subs[NTV2_SUB_NUM_DELTA].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        nd_pos += adv;
                        v = col_num_prev[j] + (uint64_t)d;
                        col_num_prev[j] = v;
                    }
                    char tmp[32];
                    int tn = snprintf(tmp, sizeof(tmp), "%llu",
                                      (unsigned long long)v);
                    if (buf_append(&name_buf, (const uint8_t *)tmp, (size_t)tn) != 0) {
                        buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                    }
                } else {
                    if (dc_pos >= subs[NTV2_SUB_DICT_CODE].len) {
                        buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                    }
                    uint64_t code;
                    size_t adv = ntv2_uvarint_decode(
                        subs[NTV2_SUB_DICT_CODE].data + dc_pos, &code);
                    if (adv == 0 || dc_pos + adv > subs[NTV2_SUB_DICT_CODE].len) {
                        buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                    }
                    dc_pos += adv;
                    ntv2_col_dict *d = &col_dict[j];
                    if (code < d->n) {
                        if (buf_append(&name_buf,
                                       (const uint8_t *)d->lits[code],
                                       d->lit_lens[code]) != 0) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                        }
                    } else if (code == d->n) {
                        if (dl_pos >= subs[NTV2_SUB_DICT_LIT].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        uint64_t lit_len;
                        adv = ntv2_uvarint_decode(
                            subs[NTV2_SUB_DICT_LIT].data + dl_pos, &lit_len);
                        if (adv == 0 || dl_pos + adv > subs[NTV2_SUB_DICT_LIT].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        dl_pos += adv;
                        if (dl_pos + lit_len > subs[NTV2_SUB_DICT_LIT].len) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_CORRUPT; goto out;
                        }
                        if (col_dict_add(d,
                                         (const char *)(subs[NTV2_SUB_DICT_LIT].data + dl_pos),
                                         (size_t)lit_len) != 0) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                        }
                        if (buf_append(&name_buf,
                                       subs[NTV2_SUB_DICT_LIT].data + dl_pos,
                                       (size_t)lit_len) != 0) {
                            buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
                        }
                        dl_pos += (size_t)lit_len;
                    } else {
                        buf_free(&name_buf);
                        rc = TTIO_RANS_ERR_NTV2_DICT_OVERFLOW; goto out;
                    }
                }
            }
            out_name_len = name_buf.len;
            out_name = (char *)malloc(out_name_len + 1);
            if (!out_name) {
                buf_free(&name_buf); rc = TTIO_RANS_ERR_ALLOC; goto out;
            }
            if (out_name_len > 0) memcpy(out_name, name_buf.data, out_name_len);
            out_name[out_name_len] = '\0';
            buf_free(&name_buf);
        } else { /* VERB */
            if (vl_pos >= subs[NTV2_SUB_VERB_LIT].len) {
                rc = TTIO_RANS_ERR_CORRUPT; goto out;
            }
            uint64_t lit_len;
            size_t adv = ntv2_uvarint_decode(
                subs[NTV2_SUB_VERB_LIT].data + vl_pos, &lit_len);
            if (adv == 0 || vl_pos + adv > subs[NTV2_SUB_VERB_LIT].len) {
                rc = TTIO_RANS_ERR_CORRUPT; goto out;
            }
            vl_pos += adv;
            if (vl_pos + lit_len > subs[NTV2_SUB_VERB_LIT].len) {
                rc = TTIO_RANS_ERR_CORRUPT; goto out;
            }
            out_name_len = (size_t)lit_len;
            out_name = (char *)malloc(out_name_len + 1);
            if (!out_name) { rc = TTIO_RANS_ERR_ALLOC; goto out; }
            if (out_name_len > 0) {
                memcpy(out_name, subs[NTV2_SUB_VERB_LIT].data + vl_pos, out_name_len);
            }
            out_name[out_name_len] = '\0';
            vl_pos += (size_t)lit_len;
        }

        /* Push to pool — re-tokenise the decoded name for future MATCH-K. */
        if (pool_len == NTV2_POOL_SIZE) {
            pool_entry_clear(&pool[0]);
            for (uint8_t k = 1; k < NTV2_POOL_SIZE; k++) {
                pool[k - 1] = pool[k];
            }
            memset(&pool[NTV2_POOL_SIZE - 1], 0, sizeof(pool[0]));
            pool_len--;
        }
        ntv2_pool_entry *slot = &pool[pool_len];
        slot->name = (char *)malloc(out_name_len > 0 ? out_name_len : 1);
        if (!slot->name) {
            free(out_name);
            rc = TTIO_RANS_ERR_ALLOC; goto out;
        }
        if (out_name_len > 0) memcpy(slot->name, out_name, out_name_len);
        slot->name_len = out_name_len;
        if (ntv2_tokenise(out_name, slot->types, slot->starts, slot->lens,
                          &slot->n_tokens, slot->nums) != 0) {
            free(slot->name); slot->name = NULL;
            free(out_name);
            rc = TTIO_RANS_ERR_CORRUPT;
            goto out;
        }
        pool_len++;

        names[*names_idx] = out_name;
        (*names_idx)++;
    }

out:
    free(flags);
    free(pool_idxs);
    free(match_ks);
    for (uint8_t k = 0; k < pool_len; k++) pool_entry_clear(&pool[k]);
    for (int j = 0; j < NTV2_MAX_TOKENS; j++) col_dict_free(&col_dict[j]);
    for (int s = 0; s < NTV2_SUB_COUNT; s++) sub_free(&subs[s]);
    return rc;
}

/* ──────── Public API ──────── */

size_t ttio_name_tok_v2_max_encoded_size(uint64_t n_reads, uint64_t total_name_bytes) {
    /* Worst case: header + offsets + per-block substream framing
     * + verbatim fallback for every byte of name + slack. */
    uint64_t n_blocks = n_reads == 0 ? 0
                                     : (n_reads + NTV2_BLOCK_SIZE - 1) / NTV2_BLOCK_SIZE;
    size_t hdr = NTV2_HEADER_FIXED + (size_t)n_blocks * 4;
    size_t per_block_overhead = 8 + 5 * NTV2_SUB_COUNT + 64;
    size_t per_block_rans_overhead = 1037 * NTV2_SUB_COUNT;
    size_t name_overhead = (size_t)n_reads * 10;
    return hdr + (size_t)n_blocks * (per_block_overhead + per_block_rans_overhead)
         + (size_t)total_name_bytes + name_overhead + 1024;
}

int ttio_name_tok_v2_encode(const char * const *names, uint64_t n_reads,
                            uint8_t *out, size_t *out_len) {
    if (!out || !out_len) return TTIO_RANS_ERR_PARAM;
    size_t cap = *out_len;

    /* Empty stream: 12-byte header with flags.bit0 = 1. */
    if (n_reads == 0) {
        if (cap < NTV2_HEADER_FIXED) return TTIO_RANS_ERR_PARAM;
        memcpy(out, NTV2_MAGIC, NTV2_MAGIC_LEN);
        out[4] = NTV2_VERSION;
        out[5] = NTV2_FLAG_EMPTY;
        write_u32_le(out + 6, 0);
        write_u16_le(out + 10, 0);
        *out_len = NTV2_HEADER_FIXED;
        return TTIO_RANS_OK;
    }

    if (!names) return TTIO_RANS_ERR_PARAM;
    uint64_t n_blocks = (n_reads + NTV2_BLOCK_SIZE - 1) / NTV2_BLOCK_SIZE;
    if (n_blocks > 0xFFFF) return TTIO_RANS_ERR_PARAM;

    /* Build all block bodies first, then assemble container header. */
    ntv2_buf *blocks = (ntv2_buf *)calloc((size_t)n_blocks, sizeof(*blocks));
    if (!blocks) return TTIO_RANS_ERR_ALLOC;
    int rc = TTIO_RANS_OK;
    for (uint64_t b = 0; b < n_blocks; b++) buf_init(&blocks[b]);

    uint32_t *offsets = (uint32_t *)malloc((size_t)n_blocks * sizeof(uint32_t));
    if (!offsets) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
    uint64_t cur_off = 0;

    for (uint64_t b = 0; b < n_blocks; b++) {
        uint64_t start = b * NTV2_BLOCK_SIZE;
        uint64_t end = start + NTV2_BLOCK_SIZE;
        if (end > n_reads) end = n_reads;
        size_t n_block = (size_t)(end - start);
        rc = encode_block(names + start, n_block, &blocks[b]);
        if (rc != TTIO_RANS_OK) goto cleanup;
        if (cur_off > 0xFFFFFFFFULL) { rc = TTIO_RANS_ERR_PARAM; goto cleanup; }
        offsets[b] = (uint32_t)cur_off;
        cur_off += blocks[b].len;
    }

    /* Compute total size + bounds-check. */
    size_t hdr_size = NTV2_HEADER_FIXED + (size_t)n_blocks * 4;
    size_t total = hdr_size + (size_t)cur_off;
    if (total > cap) { rc = TTIO_RANS_ERR_PARAM; goto cleanup; }

    /* Write container header. */
    memcpy(out, NTV2_MAGIC, NTV2_MAGIC_LEN);
    out[4] = NTV2_VERSION;
    out[5] = 0;  /* flags = 0 (non-empty) */
    write_u32_le(out + 6, (uint32_t)n_reads);
    write_u16_le(out + 10, (uint16_t)n_blocks);
    for (uint64_t b = 0; b < n_blocks; b++) {
        write_u32_le(out + NTV2_HEADER_FIXED + (size_t)b * 4, offsets[b]);
    }
    /* Write block bodies. */
    size_t pos = hdr_size;
    for (uint64_t b = 0; b < n_blocks; b++) {
        if (blocks[b].len > 0) memcpy(out + pos, blocks[b].data, blocks[b].len);
        pos += blocks[b].len;
    }
    *out_len = pos;

cleanup:
    for (uint64_t b = 0; b < n_blocks; b++) buf_free(&blocks[b]);
    free(blocks);
    free(offsets);
    return rc;
}

int ttio_name_tok_v2_decode(const uint8_t *encoded, size_t encoded_size,
                            char ***out_names, uint64_t *out_n_reads) {
    if (!encoded || !out_names || !out_n_reads) return TTIO_RANS_ERR_PARAM;
    *out_names = NULL;
    *out_n_reads = 0;

    if (encoded_size < NTV2_HEADER_FIXED) return TTIO_RANS_ERR_NTV2_BAD_MAGIC;
    if (memcmp(encoded, NTV2_MAGIC, NTV2_MAGIC_LEN) != 0) {
        return TTIO_RANS_ERR_NTV2_BAD_MAGIC;
    }
    if (encoded[4] != NTV2_VERSION) return TTIO_RANS_ERR_NTV2_BAD_VERSION;
    uint8_t flags = encoded[5];
    if (flags & 0xFE) return TTIO_RANS_ERR_CORRUPT;
    uint32_t n_reads_h = read_u32_le(encoded + 6);
    uint16_t n_blocks = read_u16_le(encoded + 10);

    if (flags & NTV2_FLAG_EMPTY) {
        if (n_reads_h != 0 || n_blocks != 0) return TTIO_RANS_ERR_CORRUPT;
        char **arr = (char **)malloc(sizeof(char *));  /* trivial empty array */
        if (!arr) return TTIO_RANS_ERR_ALLOC;
        *out_names = arr;
        *out_n_reads = 0;
        return TTIO_RANS_OK;
    }

    size_t hdr_size = NTV2_HEADER_FIXED + (size_t)n_blocks * 4;
    if (hdr_size > encoded_size) return TTIO_RANS_ERR_CORRUPT;

    uint32_t *offsets = NULL;
    if (n_blocks > 0) {
        offsets = (uint32_t *)malloc((size_t)n_blocks * sizeof(uint32_t));
        if (!offsets) return TTIO_RANS_ERR_ALLOC;
        for (uint16_t b = 0; b < n_blocks; b++) {
            offsets[b] = read_u32_le(encoded + NTV2_HEADER_FIXED + (size_t)b * 4);
        }
        size_t bodies_len = encoded_size - hdr_size;
        for (uint16_t b = 0; b < n_blocks; b++) {
            if ((size_t)offsets[b] > bodies_len) {
                free(offsets); return TTIO_RANS_ERR_CORRUPT;
            }
        }
    }

    char **arr;
    if (n_reads_h > 0) {
        arr = (char **)calloc(n_reads_h, sizeof(char *));
        if (!arr) { free(offsets); return TTIO_RANS_ERR_ALLOC; }
    } else {
        arr = (char **)malloc(sizeof(char *));
        if (!arr) { free(offsets); return TTIO_RANS_ERR_ALLOC; }
    }
    uint64_t names_idx = 0;

    int rc = TTIO_RANS_OK;
    for (uint16_t b = 0; b < n_blocks; b++) {
        size_t start = hdr_size + (size_t)offsets[b];
        size_t end = (b + 1 < n_blocks)
                   ? hdr_size + (size_t)offsets[b + 1]
                   : encoded_size;
        if (end < start || end > encoded_size) { rc = TTIO_RANS_ERR_CORRUPT; break; }
        rc = decode_block(encoded + start, end - start, arr, &names_idx, n_reads_h);
        if (rc != TTIO_RANS_OK) break;
    }
    free(offsets);

    if (rc != TTIO_RANS_OK) {
        for (uint64_t i = 0; i < names_idx; i++) free(arr[i]);
        free(arr);
        return rc;
    }
    if (names_idx != n_reads_h) {
        for (uint64_t i = 0; i < names_idx; i++) free(arr[i]);
        free(arr);
        return TTIO_RANS_ERR_CORRUPT;
    }

    *out_names = arr;
    *out_n_reads = n_reads_h;
    return TTIO_RANS_OK;
}
