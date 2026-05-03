#include "mate_info_v2.h"
#include "../include/ttio_rans.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

/* varint (LEB128, little-endian base-128) */

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
        if (shift >= 64) return TTIO_RANS_ERR_CORRUPT;
    }
    return TTIO_RANS_ERR_CORRUPT;
}

/* zigzag for int64 */

uint64_t miv2_zigzag_encode_64(int64_t value) {
    return ((uint64_t)value << 1) ^ (uint64_t)(value >> 63);
}

int64_t miv2_zigzag_decode_64(uint64_t value) {
    return (int64_t)((value >> 1) ^ -(int64_t)(value & 1));
}

/* LE helpers */

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

/* substream compress / decompress via zlib.
 * MF selector byte: 0x00 = raw 2-bit pack, 0x01 = zlib-compressed. */

static int miv2_zlib_compress(const uint8_t *in, size_t in_len,
                               uint8_t *out, size_t *out_len) {
    uLongf dst = (uLongf)(*out_len);
    int rc = compress2(out, &dst, (const Bytef *)in, (uLong)in_len, 6);
    if (rc != Z_OK) return TTIO_RANS_ERR_ALLOC;
    *out_len = (size_t)dst;
    return 0;
}

static int miv2_zlib_decompress(const uint8_t *in, size_t in_len,
                                 uint8_t *out, size_t out_cap,
                                 size_t *out_len) {
    uLongf dst = (uLongf)out_cap;
    int rc = uncompress((Bytef *)out, &dst, (const Bytef *)in, (uLong)in_len);
    if (rc != Z_OK) return TTIO_RANS_ERR_CORRUPT;
    *out_len = (size_t)dst;
    return 0;
}

/* MF helpers */

/* MF classification.  Returns TTIO_RANS_ERR_PARAM if mate_chrom_id < -1. */
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
    size_t bytes = (size_t)((n + 3) / 4);
    memset(out, 0, bytes);
    for (uint64_t i = 0; i < n; i++) {
        uint8_t v = mf[i] & 0x3;
        size_t byte_idx = (size_t)(i / 4);
        size_t bit_pos  = (size_t)((i % 4) * 2);
        out[byte_idx] |= (uint8_t)(v << bit_pos);
    }
    return bytes;
}

/* MF raw-pack decode: validates each 2-bit slot; rejects 3 with TTIO_RANS_ERR_RESERVED_MF. */
static int miv2_decode_mf_raw_pack(const uint8_t *in, size_t in_len, uint64_t n, uint8_t *out_mf) {
    size_t bytes = (size_t)((n + 3) / 4);
    if (in_len < bytes) return TTIO_RANS_ERR_CORRUPT;
    for (uint64_t i = 0; i < n; i++) {
        size_t byte_idx = (size_t)(i / 4);
        size_t bit_pos  = (size_t)((i % 4) * 2);
        uint8_t v = (in[byte_idx] >> bit_pos) & 0x3;
        if (v == MIV2_MF_RESERVED) return TTIO_RANS_ERR_RESERVED_MF;
        out_mf[i] = v;
    }
    return 0;
}

/* max encoded size */

size_t ttio_mate_info_v2_max_encoded_size(uint64_t n_records) {
    /* Worst case: header + raw MF bytes + zlib-compressed NS/NP/TS.
     * Each record up to 31 raw bytes; zlib overhead is bounded.
     * Add 256 bytes of headroom. */
    size_t raw_total = (size_t)n_records * 31 + 64;
    size_t zlib_overhead = raw_total / 1000 + 256;
    return (size_t)MIV2_HEADER_SIZE + raw_total + zlib_overhead + 64;
}

/* encoder */

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

    /* 1. Classify MF for every record (validates mate_chrom_id >= -1). */
    uint8_t *mf = (uint8_t *)malloc(n_records ? n_records : 1);
    if (!mf) return TTIO_RANS_ERR_ALLOC;
    uint64_t num_cross = 0;
    for (uint64_t i = 0; i < n_records; i++) {
        int rc2 = miv2_classify_mf(mate_chrom_ids[i], own_chrom_ids[i], &mf[i]);
        if (rc2 != 0) { free(mf); return rc2; }
        if (mf[i] == MIV2_MF_CROSS_CHROM) num_cross++;
    }

    /* 2. Build NS substream (varint(mate_chrom_id) per CROSS_CHROM). */
    uint8_t *ns_raw = (uint8_t *)malloc(num_cross * 10 + 1);
    if (!ns_raw) { free(mf); return TTIO_RANS_ERR_ALLOC; }
    size_t ns_raw_size = 0;
    for (uint64_t i = 0; i < n_records; i++) {
        if (mf[i] == MIV2_MF_CROSS_CHROM) {
            ns_raw_size += miv2_varint_encode((uint64_t)mate_chrom_ids[i], ns_raw + ns_raw_size);
        }
    }

    /* 3. Build NP substream (zigzag_varint per record). */
    uint8_t *np_raw = (uint8_t *)malloc(n_records * 10 + 1);
    if (!np_raw) { free(mf); free(ns_raw); return TTIO_RANS_ERR_ALLOC; }
    size_t np_raw_size = 0;
    for (uint64_t i = 0; i < n_records; i++) {
        int64_t v = (mf[i] == MIV2_MF_SAME_CHROM) ?
                    (mate_positions[i] - own_positions[i]) : mate_positions[i];
        np_raw_size += miv2_varint_encode(miv2_zigzag_encode_64(v), np_raw + np_raw_size);
    }

    /* 4. Build TS substream (zigzag_varint per record). */
    uint8_t *ts_raw = (uint8_t *)malloc(n_records * 10 + 1);
    if (!ts_raw) { free(mf); free(ns_raw); free(np_raw); return TTIO_RANS_ERR_ALLOC; }
    size_t ts_raw_size = 0;
    for (uint64_t i = 0; i < n_records; i++) {
        ts_raw_size += miv2_varint_encode(
            miv2_zigzag_encode_64((int64_t)template_lengths[i]),
            ts_raw + ts_raw_size);
    }

    /* 5. Compress NS / NP / TS with zlib. */
    size_t ns_z_cap = ns_raw_size + ns_raw_size / 1000 + 64;
    uint8_t *ns_z = (uint8_t *)malloc(ns_z_cap ? ns_z_cap : 1);
    size_t ns_z_size = 0;
    if (!ns_z) { free(mf); free(ns_raw); free(np_raw); free(ts_raw); return TTIO_RANS_ERR_ALLOC; }
    if (ns_raw_size > 0) {
        ns_z_size = ns_z_cap;
        if (miv2_zlib_compress(ns_raw, ns_raw_size, ns_z, &ns_z_size) != 0) {
            free(mf); free(ns_raw); free(np_raw); free(ts_raw); free(ns_z);
            return TTIO_RANS_ERR_ALLOC;
        }
    }

    size_t np_z_cap = np_raw_size + np_raw_size / 1000 + 64;
    uint8_t *np_z = (uint8_t *)malloc(np_z_cap ? np_z_cap : 1);
    size_t np_z_size = 0;
    if (!np_z) { free(mf); free(ns_raw); free(np_raw); free(ts_raw); free(ns_z); return TTIO_RANS_ERR_ALLOC; }
    if (np_raw_size > 0) {
        np_z_size = np_z_cap;
        if (miv2_zlib_compress(np_raw, np_raw_size, np_z, &np_z_size) != 0) {
            free(mf); free(ns_raw); free(np_raw); free(ts_raw); free(ns_z); free(np_z);
            return TTIO_RANS_ERR_ALLOC;
        }
    }

    size_t ts_z_cap = ts_raw_size + ts_raw_size / 1000 + 64;
    uint8_t *ts_z = (uint8_t *)malloc(ts_z_cap ? ts_z_cap : 1);
    size_t ts_z_size = 0;
    if (!ts_z) { free(mf); free(ns_raw); free(np_raw); free(ts_raw); free(ns_z); free(np_z); return TTIO_RANS_ERR_ALLOC; }
    if (ts_raw_size > 0) {
        ts_z_size = ts_z_cap;
        if (miv2_zlib_compress(ts_raw, ts_raw_size, ts_z, &ts_z_size) != 0) {
            free(mf); free(ns_raw); free(np_raw); free(ts_raw); free(ns_z); free(np_z); free(ts_z);
            return TTIO_RANS_ERR_ALLOC;
        }
    }

    /* 6. MF auto-pick: raw-pack vs zlib, take smaller. */
    size_t mf_raw_size = (size_t)((n_records + 3) / 4);
    uint8_t *mf_raw = (uint8_t *)malloc(mf_raw_size + 1);
    if (!mf_raw) {
        free(mf); free(ns_raw); free(np_raw); free(ts_raw);
        free(ns_z); free(np_z); free(ts_z);
        return TTIO_RANS_ERR_ALLOC;
    }
    if (n_records > 0) miv2_encode_mf_raw_pack(mf, n_records, mf_raw);

    size_t mf_z_cap = n_records + n_records / 1000 + 64;
    uint8_t *mf_z = (uint8_t *)malloc(mf_z_cap ? mf_z_cap : 1);
    size_t mf_z_size = 0;
    if (!mf_z) {
        free(mf); free(ns_raw); free(np_raw); free(ts_raw);
        free(ns_z); free(np_z); free(ts_z); free(mf_raw);
        return TTIO_RANS_ERR_ALLOC;
    }
    if (n_records > 0) {
        mf_z_size = mf_z_cap;
        if (miv2_zlib_compress(mf, n_records, mf_z, &mf_z_size) != 0) {
            free(mf); free(ns_raw); free(np_raw); free(ts_raw);
            free(ns_z); free(np_z); free(ts_z); free(mf_raw); free(mf_z);
            return TTIO_RANS_ERR_ALLOC;
        }
    }

    int mf_use_zlib = (n_records > 0 && mf_z_size < mf_raw_size);
    size_t mf_substream_size = 1 + (mf_use_zlib ? mf_z_size : mf_raw_size);

    /* 7. Assemble container. */
    size_t total = (size_t)MIV2_HEADER_SIZE + mf_substream_size + ns_z_size + np_z_size + ts_z_size;
    if (*out_len < total) {
        free(mf); free(ns_raw); free(np_raw); free(ts_raw);
        free(ns_z); free(np_z); free(ts_z); free(mf_raw); free(mf_z);
        return TTIO_RANS_ERR_PARAM;
    }

    memcpy(out, MIV2_MAGIC, MIV2_MAGIC_LEN);
    out[4] = MIV2_VERSION;
    out[5] = 0;
    miv2_write_u64_le(out + 6,  n_records);
    miv2_write_u32_le(out + 14, (uint32_t)num_cross);
    miv2_write_u32_le(out + 18, (uint32_t)mf_substream_size);
    miv2_write_u32_le(out + 22, (uint32_t)ns_z_size);
    miv2_write_u32_le(out + 26, (uint32_t)np_z_size);
    miv2_write_u32_le(out + 30, (uint32_t)ts_z_size);

    size_t off = (size_t)MIV2_HEADER_SIZE;
    /* MF selector byte: 0x00 = raw-pack, 0x01 = zlib-compressed. */
    out[off++] = mf_use_zlib ? MIV2_MF_RANS_O0 : MIV2_MF_RAW_PACK;
    if (mf_use_zlib) {
        memcpy(out + off, mf_z, mf_z_size);    off += mf_z_size;
    } else {
        memcpy(out + off, mf_raw, mf_raw_size); off += mf_raw_size;
    }
    memcpy(out + off, ns_z, ns_z_size); off += ns_z_size;
    memcpy(out + off, np_z, np_z_size); off += np_z_size;
    memcpy(out + off, ts_z, ts_z_size); off += ts_z_size;

    *out_len = off;
    free(mf); free(ns_raw); free(np_raw); free(ts_raw);
    free(ns_z); free(np_z); free(ts_z); free(mf_raw); free(mf_z);
    return 0;
}

/* decoder */

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
    if (!encoded || !own_chrom_ids || !own_positions ||
        !out_mate_chrom_ids || !out_mate_positions || !out_template_lengths) {
        return TTIO_RANS_ERR_PARAM;
    }
    if (encoded_size < (size_t)MIV2_HEADER_SIZE) return TTIO_RANS_ERR_CORRUPT;
    if (memcmp(encoded, MIV2_MAGIC, MIV2_MAGIC_LEN) != 0) return TTIO_RANS_ERR_CORRUPT;
    if (encoded[4] != MIV2_VERSION) return TTIO_RANS_ERR_CORRUPT;
    if (encoded[5] != 0) return TTIO_RANS_ERR_CORRUPT;

    uint64_t hdr_n = miv2_read_u64_le(encoded + 6);
    if (hdr_n != n_records) return TTIO_RANS_ERR_PARAM;
    uint32_t num_cross = miv2_read_u32_le(encoded + 14);
    uint32_t mf_len    = miv2_read_u32_le(encoded + 18);
    uint32_t ns_len    = miv2_read_u32_le(encoded + 22);
    uint32_t np_len    = miv2_read_u32_le(encoded + 26);
    uint32_t ts_len    = miv2_read_u32_le(encoded + 30);

    if ((size_t)MIV2_HEADER_SIZE + mf_len + ns_len + np_len + ts_len > encoded_size)
        return TTIO_RANS_ERR_CORRUPT;

    const uint8_t *mf_stream = encoded + MIV2_HEADER_SIZE;
    const uint8_t *ns_stream = mf_stream + mf_len;
    const uint8_t *np_stream = ns_stream + ns_len;
    const uint8_t *ts_stream = np_stream + np_len;

    /* Decode MF stream. */
    uint8_t *mf = (uint8_t *)malloc(n_records ? n_records : 1);
    if (!mf) return TTIO_RANS_ERR_ALLOC;
    if (mf_len < 1) { free(mf); return TTIO_RANS_ERR_CORRUPT; }
    int rc = 0;
    if (mf_stream[0] == MIV2_MF_RAW_PACK) {
        /* Raw 2-bit pack -- validates each slot, rejects 3. */
        rc = miv2_decode_mf_raw_pack(mf_stream + 1, mf_len - 1, n_records, mf);
    } else if (mf_stream[0] == MIV2_MF_RANS_O0) {
        /* zlib-compressed MF byte stream (1 byte per record). */
        if (n_records == 0) {
            rc = 0;
        } else {
            size_t mf_dec = 0;
            rc = miv2_zlib_decompress(mf_stream + 1, mf_len - 1, mf, n_records, &mf_dec);
            if (rc == 0) {
                if (mf_dec != n_records) {
                    rc = TTIO_RANS_ERR_CORRUPT;
                } else {
                    for (uint64_t i = 0; i < n_records; i++) {
                        if (mf[i] == MIV2_MF_RESERVED) { rc = TTIO_RANS_ERR_RESERVED_MF; break; }
                        if (mf[i] > MIV2_MF_RESERVED)  { rc = TTIO_RANS_ERR_CORRUPT; break; }
                    }
                }
            }
        }
    } else {
        rc = TTIO_RANS_ERR_CORRUPT;
    }
    if (rc != 0) { free(mf); return rc; }

    /* Decode NS stream (zlib -> varint bytes). */
    uint8_t *ns_buf = NULL;
    size_t ns_decoded_size = 0;
    if (num_cross > 0) {
        size_t ns_cap = (size_t)num_cross * 10 + 16;
        ns_buf = (uint8_t *)malloc(ns_cap);
        if (!ns_buf) { free(mf); return TTIO_RANS_ERR_ALLOC; }
        rc = miv2_zlib_decompress(ns_stream, ns_len, ns_buf, ns_cap, &ns_decoded_size);
        if (rc != 0) { free(mf); free(ns_buf); return rc; }
    }

    /* Decode NP stream. */
    size_t np_cap = (size_t)n_records * 10 + 16;
    uint8_t *np_buf = (uint8_t *)malloc(np_cap ? np_cap : 1);
    if (!np_buf) { free(mf); free(ns_buf); return TTIO_RANS_ERR_ALLOC; }
    size_t np_decoded_size = 0;
    if (np_len > 0) {
        rc = miv2_zlib_decompress(np_stream, np_len, np_buf, np_cap, &np_decoded_size);
        if (rc != 0) { free(mf); free(ns_buf); free(np_buf); return rc; }
    }

    /* Decode TS stream. */
    size_t ts_cap = (size_t)n_records * 10 + 16;
    uint8_t *ts_buf = (uint8_t *)malloc(ts_cap ? ts_cap : 1);
    if (!ts_buf) { free(mf); free(ns_buf); free(np_buf); return TTIO_RANS_ERR_ALLOC; }
    size_t ts_decoded_size = 0;
    if (ts_len > 0) {
        rc = miv2_zlib_decompress(ts_stream, ts_len, ts_buf, ts_cap, &ts_decoded_size);
        if (rc != 0) { free(mf); free(ns_buf); free(np_buf); free(ts_buf); return rc; }
    }

    /* Walk streams, reconstruct tuples. */
    size_t ns_off = 0, np_off = 0, ts_off = 0;
    uint32_t ns_consumed = 0;
    for (uint64_t i = 0; i < n_records; i++) {
        /* mate_chrom_id from MF. */
        if (mf[i] == MIV2_MF_NO_MATE) {
            out_mate_chrom_ids[i] = -1;
        } else if (mf[i] == MIV2_MF_SAME_CHROM) {
            int32_t own = (own_chrom_ids[i] == MIV2_OWN_UNMAPPED) ? -1 : (int32_t)own_chrom_ids[i];
            out_mate_chrom_ids[i] = own;
        } else {  /* CROSS_CHROM */
            uint64_t v; size_t c;
            int dr = miv2_varint_decode(ns_buf + ns_off, ns_decoded_size - ns_off, &v, &c);
            if (dr != 0) { free(mf); free(ns_buf); free(np_buf); free(ts_buf); return dr; }
            ns_off += c;
            ns_consumed++;
            out_mate_chrom_ids[i] = (int32_t)v;
        }
        /* mate_pos from NP. */
        {
            uint64_t v; size_t c;
            int dr = miv2_varint_decode(np_buf + np_off, np_decoded_size - np_off, &v, &c);
            if (dr != 0) { free(mf); free(ns_buf); free(np_buf); free(ts_buf); return dr; }
            np_off += c;
            int64_t pos = miv2_zigzag_decode_64(v);
            out_mate_positions[i] = (mf[i] == MIV2_MF_SAME_CHROM) ?
                                    (own_positions[i] + pos) : pos;
        }
        /* tlen from TS. */
        {
            uint64_t v; size_t c;
            int dr = miv2_varint_decode(ts_buf + ts_off, ts_decoded_size - ts_off, &v, &c);
            if (dr != 0) { free(mf); free(ns_buf); free(np_buf); free(ts_buf); return dr; }
            ts_off += c;
            out_template_lengths[i] = (int32_t)miv2_zigzag_decode_64(v);
        }
    }

    /* I4: NS length conservation check. */
    if (ns_consumed != num_cross || ns_off != ns_decoded_size) {
        free(mf); free(ns_buf); free(np_buf); free(ts_buf);
        return TTIO_RANS_ERR_NS_LENGTH_MISMATCH;
    }

    free(mf); free(ns_buf); free(np_buf); free(ts_buf);
    return 0;
}
