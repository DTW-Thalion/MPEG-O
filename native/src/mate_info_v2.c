#include "mate_info_v2.h"
#include "../include/ttio_rans.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* ── varint (LEB128, little-endian base-128) ───────────────────── */

size_t miv2_varint_encode(uint64_t value, uint8_t *out) {
    size_t i = 0;
    while (value >= 0x80) {
        out[i++] = (uint8_t)(value | 0x80);
        value >>= 7;
    }
    out[i++] = (uint8_t)value;
    return i;
}

int miv2_varint_decode(const uint8_t *in, size_t in_len, uint64_t *out_value, size_t *out_consumed) {
    uint64_t result = 0;
    size_t i = 0;
    int shift = 0;
    while (i < in_len) {
        uint8_t b = in[i++];
        result |= ((uint64_t)(b & 0x7F)) << shift;
        if ((b & 0x80) == 0) {
            *out_value = result;
            *out_consumed = i;
            return 0;
        }
        shift += 7;
        if (shift >= 64) return TTIO_RANS_ERR_CORRUPT;  /* overflow */
    }
    return TTIO_RANS_ERR_CORRUPT;  /* ran out of bytes */
}

/* ── zigzag for int64 ──────────────────────────────────────────── */

uint64_t miv2_zigzag_encode_64(int64_t value) {
    return ((uint64_t)value << 1) ^ (uint64_t)(value >> 63);
}

int64_t miv2_zigzag_decode_64(uint64_t value) {
    return (int64_t)((value >> 1) ^ -(int64_t)(value & 1));
}

/* ── Static helpers ────────────────────────────────────────────── */

/* MF classification — central to the taxonomy.
 * Returns 0 on success, TTIO_RANS_ERR_PARAM on invalid input. */
static int miv2_classify_mf(int32_t mate_chrom_id, uint16_t own_chrom_id, uint8_t *out_mf) {
    if (mate_chrom_id < -1) return TTIO_RANS_ERR_PARAM;
    int32_t own = (own_chrom_id == MIV2_OWN_UNMAPPED) ? -1 : (int32_t)own_chrom_id;
    if (mate_chrom_id == -1) {
        *out_mf = MIV2_MF_NO_MATE;
    } else if (mate_chrom_id == own) {
        *out_mf = MIV2_MF_SAME_CHROM;
    } else {
        *out_mf = MIV2_MF_CROSS_CHROM;
    }
    return 0;
}

/* MF raw-pack encode: 2 bits per MF, 4 per byte, LSB-first. */
static size_t miv2_encode_mf_raw_pack(const uint8_t *mf, uint64_t n, uint8_t *out) {
    size_t bytes = (n + 3) / 4;
    memset(out, 0, bytes);
    for (uint64_t i = 0; i < n; i++) {
        uint8_t v = mf[i] & 0x3;
        size_t byte_idx = i / 4;
        size_t bit_pos = (i % 4) * 2;
        out[byte_idx] |= (uint8_t)(v << bit_pos);
    }
    return bytes;
}

/* MF raw-pack decode: validates each 2-bit slot is in {0,1,2}. */
static int miv2_decode_mf_raw_pack(const uint8_t *in, size_t in_len, uint64_t n, uint8_t *out_mf) {
    size_t bytes = (n + 3) / 4;
    if (in_len < bytes) return TTIO_RANS_ERR_CORRUPT;
    for (uint64_t i = 0; i < n; i++) {
        size_t byte_idx = i / 4;
        size_t bit_pos = (i % 4) * 2;
        uint8_t v = (in[byte_idx] >> bit_pos) & 0x3;
        if (v == MIV2_MF_RESERVED) return TTIO_RANS_ERR_RESERVED_MF;
        out_mf[i] = v;
    }
    return 0;
}

static void miv2_write_u32_le(uint8_t *buf, uint32_t v) {
    buf[0] = (uint8_t)(v & 0xff);
    buf[1] = (uint8_t)((v >> 8) & 0xff);
    buf[2] = (uint8_t)((v >> 16) & 0xff);
    buf[3] = (uint8_t)((v >> 24) & 0xff);
}
static void miv2_write_u64_le(uint8_t *buf, uint64_t v) {
    for (int i = 0; i < 8; i++) buf[i] = (uint8_t)((v >> (i*8)) & 0xff);
}
static uint32_t miv2_read_u32_le(const uint8_t *buf) {
    return (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) |
           ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
}
static uint64_t miv2_read_u64_le(const uint8_t *buf) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= ((uint64_t)buf[i]) << (i*8);
    return v;
}

/* ── Public API ────────────────────────────────────────────────── */

size_t ttio_mate_info_v2_max_encoded_size(uint64_t n_records) {
    /* Worst case: container header + raw input bytes per substream
     * (one byte/record MF + 10 bytes/record varint NP + 10 bytes/record
     * zigzag TS + 10 bytes/record NS for all-cross) + rANS-O0 overhead
     * (~1037 bytes baseline per substream: 9 header + 1024 freq + ~4 payload).
     * rANS-O0 max encoded ≈ 1040 + raw_in_size. */
    size_t raw_per_substream = 1 + 10 + 10 + 10;  /* MF + NS + NP + TS per record */
    size_t rans_o0_overhead_per_stream = 1040;
    return 34 + (size_t)n_records * raw_per_substream + 4 * rans_o0_overhead_per_stream;
}

int ttio_mate_info_v2_encode(
    const int32_t  *mate_chrom_ids,
    const int64_t  *mate_positions,
    const int32_t  *template_lengths,
    const uint16_t *own_chrom_ids,
    const int64_t  *own_positions,
    uint64_t        n_records,
    uint8_t        *out,
    size_t         *out_len)
{
    if (!mate_chrom_ids || !mate_positions || !template_lengths ||
        !own_chrom_ids || !own_positions || !out || !out_len) {
        return TTIO_RANS_ERR_PARAM;
    }

    uint8_t *mf = NULL;
    uint8_t *ns_buf = NULL, *np_buf = NULL, *ts_buf = NULL;
    uint8_t *mf_raw = NULL, *mf_rans = NULL;
    uint8_t *ns_rans = NULL, *np_rans = NULL, *ts_rans = NULL;
    int rc;

    /* 1. Classify MF for every record (also validates inputs). */
    if (n_records > 0) {
        mf = malloc(n_records);
        if (!mf) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
    }
    uint64_t num_cross = 0;
    for (uint64_t i = 0; i < n_records; i++) {
        rc = miv2_classify_mf(mate_chrom_ids[i], own_chrom_ids[i], &mf[i]);
        if (rc != 0) goto cleanup;
        if (mf[i] == MIV2_MF_CROSS_CHROM) num_cross++;
    }

    /* 2. Build NS substream (varint(mate_chrom_id) per CROSS_CHROM record). */
    size_t ns_pos_size = 0;
    if (num_cross > 0) {
        ns_buf = malloc(num_cross * 10 + 1);
        if (!ns_buf) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        for (uint64_t i = 0; i < n_records; i++) {
            if (mf[i] == MIV2_MF_CROSS_CHROM) {
                ns_pos_size += miv2_varint_encode((uint64_t)mate_chrom_ids[i], ns_buf + ns_pos_size);
            }
        }
    }

    /* 3. Build NP substream (zigzag_varint per record). */
    size_t np_pos_size = 0;
    if (n_records > 0) {
        np_buf = malloc(n_records * 10 + 1);
        if (!np_buf) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        for (uint64_t i = 0; i < n_records; i++) {
            int64_t v;
            if (mf[i] == MIV2_MF_SAME_CHROM) {
                v = mate_positions[i] - own_positions[i];
            } else {
                v = mate_positions[i];
            }
            np_pos_size += miv2_varint_encode(miv2_zigzag_encode_64(v), np_buf + np_pos_size);
        }
    }

    /* 4. Build TS substream (zigzag_varint per record). */
    size_t ts_pos_size = 0;
    if (n_records > 0) {
        ts_buf = malloc(n_records * 10 + 1);
        if (!ts_buf) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        for (uint64_t i = 0; i < n_records; i++) {
            ts_pos_size += miv2_varint_encode(
                miv2_zigzag_encode_64((int64_t)template_lengths[i]),
                ts_buf + ts_pos_size);
        }
    }

    /* 5. MF auto-pick: try raw-pack vs rANS-O0, take smaller. */
    size_t mf_raw_size = (n_records + 3) / 4;
    if (n_records > 0) {
        mf_raw = malloc(mf_raw_size + 1);
        if (!mf_raw) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        miv2_encode_mf_raw_pack(mf, n_records, mf_raw);
    }

    size_t mf_rans_cap = ttio_rans_o0_max_encoded_size(n_records);
    size_t mf_rans_size = mf_rans_cap;
    mf_rans = malloc(mf_rans_cap > 0 ? mf_rans_cap : 1);
    if (!mf_rans) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
    rc = ttio_rans_o0_encode(mf, n_records, mf_rans, &mf_rans_size);
    if (rc != 0) goto cleanup;

    int mf_use_rans = (mf_rans_size < mf_raw_size);
    size_t mf_substream_size = 1 + (mf_use_rans ? mf_rans_size : mf_raw_size);

    /* 6. rANS-O0-encode the NS/NP/TS substreams. */
    size_t ns_rans_size = 0;
    if (ns_pos_size > 0) {
        size_t cap = ttio_rans_o0_max_encoded_size(ns_pos_size);
        ns_rans = malloc(cap);
        if (!ns_rans) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        ns_rans_size = cap;
        rc = ttio_rans_o0_encode(ns_buf, ns_pos_size, ns_rans, &ns_rans_size);
        if (rc != 0) goto cleanup;
    }

    size_t np_rans_size = 0;
    if (np_pos_size > 0) {
        size_t cap = ttio_rans_o0_max_encoded_size(np_pos_size);
        np_rans = malloc(cap);
        if (!np_rans) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        np_rans_size = cap;
        rc = ttio_rans_o0_encode(np_buf, np_pos_size, np_rans, &np_rans_size);
        if (rc != 0) goto cleanup;
    }

    size_t ts_rans_size = 0;
    if (ts_pos_size > 0) {
        size_t cap = ttio_rans_o0_max_encoded_size(ts_pos_size);
        ts_rans = malloc(cap);
        if (!ts_rans) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        ts_rans_size = cap;
        rc = ttio_rans_o0_encode(ts_buf, ts_pos_size, ts_rans, &ts_rans_size);
        if (rc != 0) goto cleanup;
    }

    /* 7. Assemble container. */
    size_t total = MIV2_HEADER_SIZE + mf_substream_size + ns_rans_size + np_rans_size + ts_rans_size;
    if (*out_len < total) { rc = TTIO_RANS_ERR_PARAM; goto cleanup; }

    memcpy(out, MIV2_MAGIC, MIV2_MAGIC_LEN);
    out[4] = MIV2_VERSION;
    out[5] = 0;
    miv2_write_u64_le(out + 6,  n_records);
    miv2_write_u32_le(out + 14, (uint32_t)num_cross);
    miv2_write_u32_le(out + 18, (uint32_t)mf_substream_size);
    miv2_write_u32_le(out + 22, (uint32_t)ns_rans_size);
    miv2_write_u32_le(out + 26, (uint32_t)np_rans_size);
    miv2_write_u32_le(out + 30, (uint32_t)ts_rans_size);

    size_t off = MIV2_HEADER_SIZE;
    out[off++] = mf_use_rans ? MIV2_MF_RANS_O0 : MIV2_MF_RAW_PACK;
    if (mf_use_rans) { memcpy(out + off, mf_rans, mf_rans_size); off += mf_rans_size; }
    else if (mf_raw_size > 0) { memcpy(out + off, mf_raw, mf_raw_size); off += mf_raw_size; }
    if (ns_rans_size > 0) { memcpy(out + off, ns_rans, ns_rans_size); off += ns_rans_size; }
    if (np_rans_size > 0) { memcpy(out + off, np_rans, np_rans_size); off += np_rans_size; }
    if (ts_rans_size > 0) { memcpy(out + off, ts_rans, ts_rans_size); off += ts_rans_size; }

    *out_len = off;
    rc = 0;

cleanup:
    free(mf); free(ns_buf); free(np_buf); free(ts_buf);
    free(mf_raw); free(mf_rans);
    free(ns_rans); free(np_rans); free(ts_rans);
    return rc;
}

int ttio_mate_info_v2_decode(
    const uint8_t  *encoded,
    size_t          encoded_size,
    const uint16_t *own_chrom_ids,
    const int64_t  *own_positions,
    uint64_t        n_records,
    int32_t        *out_mate_chrom_ids,
    int64_t        *out_mate_positions,
    int32_t        *out_template_lengths)
{
    if (!encoded || (n_records > 0 && (!own_chrom_ids || !own_positions ||
        !out_mate_chrom_ids || !out_mate_positions || !out_template_lengths))) {
        return TTIO_RANS_ERR_PARAM;
    }
    if (encoded_size < MIV2_HEADER_SIZE) return TTIO_RANS_ERR_CORRUPT;
    if (memcmp(encoded, MIV2_MAGIC, MIV2_MAGIC_LEN) != 0) return TTIO_RANS_ERR_CORRUPT;
    if (encoded[4] != MIV2_VERSION) return TTIO_RANS_ERR_CORRUPT;
    if (encoded[5] != 0) return TTIO_RANS_ERR_CORRUPT;

    uint64_t hdr_n_records = miv2_read_u64_le(encoded + 6);
    if (hdr_n_records != n_records) return TTIO_RANS_ERR_PARAM;
    uint32_t num_cross  = miv2_read_u32_le(encoded + 14);
    uint32_t mf_len     = miv2_read_u32_le(encoded + 18);
    uint32_t ns_len     = miv2_read_u32_le(encoded + 22);
    uint32_t np_len     = miv2_read_u32_le(encoded + 26);
    uint32_t ts_len     = miv2_read_u32_le(encoded + 30);

    if ((size_t)MIV2_HEADER_SIZE + mf_len + ns_len + np_len + ts_len > encoded_size)
        return TTIO_RANS_ERR_CORRUPT;

    const uint8_t *mf_stream = encoded + MIV2_HEADER_SIZE;
    const uint8_t *ns_stream = mf_stream + mf_len;
    const uint8_t *np_stream = ns_stream + ns_len;
    const uint8_t *ts_stream = np_stream + np_len;

    uint8_t *mf = NULL, *ns_buf = NULL, *np_buf = NULL, *ts_buf = NULL;
    int rc;

    if (n_records > 0) {
        mf = malloc(n_records);
        if (!mf) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
    }

    /* Decode MF stream. */
    if (mf_len < 1) { rc = TTIO_RANS_ERR_CORRUPT; goto cleanup; }
    if (mf_stream[0] == MIV2_MF_RAW_PACK) {
        rc = miv2_decode_mf_raw_pack(mf_stream + 1, mf_len - 1, n_records, mf);
        if (rc != 0) goto cleanup;
    } else if (mf_stream[0] == MIV2_MF_RANS_O0) {
        size_t decoded_size;
        rc = ttio_rans_o0_decode(mf_stream + 1, mf_len - 1, mf, n_records, &decoded_size);
        if (rc != 0) goto cleanup;
        if (decoded_size != n_records) { rc = TTIO_RANS_ERR_CORRUPT; goto cleanup; }
        for (uint64_t i = 0; i < n_records; i++) {
            if (mf[i] == MIV2_MF_RESERVED) { rc = TTIO_RANS_ERR_RESERVED_MF; goto cleanup; }
            if (mf[i] > MIV2_MF_RESERVED)  { rc = TTIO_RANS_ERR_CORRUPT; goto cleanup; }
        }
    } else {
        rc = TTIO_RANS_ERR_CORRUPT; goto cleanup;
    }

    /* Decode NS stream (rANS-O0 -> varint bytes). */
    size_t ns_decoded_size = 0;
    size_t ns_decoded_cap = (size_t)num_cross * 10 + 16;
    if (ns_len > 0 && num_cross > 0) {
        ns_buf = malloc(ns_decoded_cap);
        if (!ns_buf) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        rc = ttio_rans_o0_decode(ns_stream, ns_len, ns_buf, ns_decoded_cap, &ns_decoded_size);
        if (rc != 0) goto cleanup;
    }

    /* Decode NP stream. */
    size_t np_decoded_size = 0;
    size_t np_decoded_cap = (size_t)n_records * 10 + 16;
    if (np_len > 0 && n_records > 0) {
        np_buf = malloc(np_decoded_cap);
        if (!np_buf) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        rc = ttio_rans_o0_decode(np_stream, np_len, np_buf, np_decoded_cap, &np_decoded_size);
        if (rc != 0) goto cleanup;
    }

    /* Decode TS stream. */
    size_t ts_decoded_size = 0;
    size_t ts_decoded_cap = (size_t)n_records * 10 + 16;
    if (ts_len > 0 && n_records > 0) {
        ts_buf = malloc(ts_decoded_cap);
        if (!ts_buf) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup; }
        rc = ttio_rans_o0_decode(ts_stream, ts_len, ts_buf, ts_decoded_cap, &ts_decoded_size);
        if (rc != 0) goto cleanup;
    }

    /* Walk the streams, reconstructing tuples. */
    size_t ns_off = 0, np_off = 0, ts_off = 0;
    uint32_t ns_consumed_count = 0;
    for (uint64_t i = 0; i < n_records; i++) {
        if (mf[i] == MIV2_MF_NO_MATE) {
            out_mate_chrom_ids[i] = -1;
        } else if (mf[i] == MIV2_MF_SAME_CHROM) {
            int32_t own = (own_chrom_ids[i] == MIV2_OWN_UNMAPPED) ? -1 : (int32_t)own_chrom_ids[i];
            out_mate_chrom_ids[i] = own;
        } else {
            uint64_t v;
            size_t consumed;
            int dr = miv2_varint_decode(ns_buf + ns_off, ns_decoded_size - ns_off, &v, &consumed);
            if (dr != 0) { rc = dr; goto cleanup; }
            ns_off += consumed;
            ns_consumed_count++;
            out_mate_chrom_ids[i] = (int32_t)v;
        }

        {
            uint64_t v;
            size_t consumed;
            int dr = miv2_varint_decode(np_buf + np_off, np_decoded_size - np_off, &v, &consumed);
            if (dr != 0) { rc = dr; goto cleanup; }
            np_off += consumed;
            int64_t np_signed = miv2_zigzag_decode_64(v);
            if (mf[i] == MIV2_MF_SAME_CHROM) {
                out_mate_positions[i] = own_positions[i] + np_signed;
            } else {
                out_mate_positions[i] = np_signed;
            }
        }

        {
            uint64_t v;
            size_t consumed;
            int dr = miv2_varint_decode(ts_buf + ts_off, ts_decoded_size - ts_off, &v, &consumed);
            if (dr != 0) { rc = dr; goto cleanup; }
            ts_off += consumed;
            out_template_lengths[i] = (int32_t)miv2_zigzag_decode_64(v);
        }
    }

    /* I4: NS length conservation check. */
    if (ns_consumed_count != num_cross || ns_off != ns_decoded_size) {
        rc = TTIO_RANS_ERR_NS_LENGTH_MISMATCH; goto cleanup;
    }

    rc = 0;

cleanup:
    free(mf); free(ns_buf); free(np_buf); free(ts_buf);
    return rc;
}
