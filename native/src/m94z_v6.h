/* native/src/m94z_v6.h
 *
 * M94.Z V6 qualities coder: segmented adaptive coding. A block's
 * qualities are split into N contiguous segments at read boundaries;
 * each segment is one independent chain with its own model and coder
 * state, so segments encode and decode in parallel and the output
 * bytes do not depend on how the work was scheduled.
 *
 * Wire format: docs/codecs/m94z_v6.md.
 *
 * Context word, low to high:
 *   [ qctx : qbits ][ pos : pbits ][ delta : dbits ][ sctx : sbits ]
 *   qctx  = (qctx << qshift) + q, rolled after coding q, reset per read
 *   pos   = MIN((1<<pbits)-1, (len-1-i) >> pshift)
 *   delta = MIN((1<<dbits)-1, |q_prev - q_prev2|), 0 for the first two
 *           symbols of a read, reset per read
 *
 * With sbits 0 the context is qualities and the read-length table
 * alone, and a decoder needs no sequence bytes. With sbits > 0 the
 * sctx field is V5's: a rolling window of 2-bit base codes, rolled
 * BEFORE coding q_i so the window includes the current base, reset
 * per read. A stream carrying sbits > 0 cannot be decoded without
 * the sequences channel.
 *
 * Functions return 0 or a TTIO_SEQCTX_ERR_* value.
 */
#ifndef TTIO_M94Z_V6_H
#define TTIO_M94Z_V6_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t qbits, qshift, pbits, pshift, dbits;
    /* Total frequency mass the per-segment models are seeded with.
     * Encode-side only: the resulting weights are written into the
     * body, so a decoder never needs this. Larger seeds start closer
     * to the block's marginal distribution but adapt more slowly. */
    uint16_t seed_total;
    /* Sequence-context width, 0 for none. Last so the positional
     * initialisers that predate it still mean what they did. */
    uint8_t sbits;
} ttio_v6_param;

/* The quality values a block actually uses, mapped to a dense
 * alphabet. Every segment restarts its model from a cold prior, so the
 * prior must not spread mass over symbols the block never emits: with
 * binned Illumina qualities the real alphabet is a handful of values
 * and a 256-symbol prior costs several bits per symbol that a short
 * segment never earns back. V4 gets the same effect from its stats
 * pass; V6 carries the alphabet in the body header so every segment
 * and both directions agree on it. */
typedef struct {
    uint8_t  map[256];    /* quality byte -> dense index */
    uint8_t  inv[256];    /* dense index -> quality byte, ascending */
    uint16_t seed[256];   /* per-symbol seed frequency, indexed densely */
    uint32_t seed_total;  /* sum of seed[0..n-1] */
    unsigned n;           /* alphabet size, 1..256 */
} ttio_v6_alphabet;

/* Build from a block's qualities: the dense alphabet, plus seed
 * frequencies proportional to the block's symbol histogram scaled to
 * about seed_total. Every present symbol gets at least 1. A segment
 * primed with these starts at the block's marginal distribution rather
 * than at a uniform prior, which is where most of the per-segment
 * warm-up cost was going. n_qualities may be 0, giving n = 1. */
void ttio_v6_alphabet_build(const uint8_t *qual, size_t n_qualities,
                            unsigned seed_total, ttio_v6_alphabet *ab);

/* Provisional until the Phase 1 ratio sweep fixes it. */
extern const ttio_v6_param TTIO_V6_DEFAULT;

#define TTIO_V6_MAX_CTX_BITS 16

/* sbits = TTIO_V6_SBITS_AUTO asks the encoder to choose the width,
 * by coding segment 0 each way and keeping the smallest. That costs
 * about one segment per candidate, against a block of N of them, so
 * it is affordable where racing whole blocks would not be. The
 * chosen width goes into the body header, so a decoder never repeats
 * the choice. With no sequences the answer is 0 without probing. */
#define TTIO_V6_SBITS_AUTO 0xFFu

/* One segment. lengths/n_reads describe ONLY this segment's reads;
 * qual holds sum(lengths) bytes. *out_len is capacity in, bytes out.
 * The chain body is the bare range-coded stream: the parameters live
 * in the block body header, not here. */
/* seq, when pm->sbits > 0, is n_qualities base bytes parallel to
 * qual. NULL is an error in that case, and ignored otherwise. */
int ttio_v6_chain_encode_seq(const ttio_v6_param *pm,
                             const ttio_v6_alphabet *ab,
                             const uint8_t *qual, const uint8_t *seq,
                             const uint32_t *lengths, size_t n_reads,
                             uint8_t *out, size_t *out_len);

int ttio_v6_chain_decode_seq(const ttio_v6_param *pm,
                             const ttio_v6_alphabet *ab,
                             const uint8_t *in, size_t in_len,
                             const uint8_t *seq,
                             const uint32_t *lengths, size_t n_reads,
                             uint8_t *qual_out, size_t n_qualities);

int ttio_v6_chain_encode(const ttio_v6_param *pm,
                         const ttio_v6_alphabet *ab,
                         const uint8_t *qual,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *out, size_t *out_len);

int ttio_v6_chain_decode(const ttio_v6_param *pm,
                         const ttio_v6_alphabet *ab,
                         const uint8_t *in, size_t in_len,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *qual_out, size_t n_qualities);

/* Segment size trades ratio against how many segments a block holds.
 * 256 Ki was sized for the number of chains a GPU could run at once;
 * that backend is gone, and 16 cores are served by far fewer segments
 * than it bought.
 *
 * Swept at the shipped context (Q6 qshift7 P4 pshift4 D1, seed 256)
 * with native/bench/bench_v6_ratio, which compares against the
 * strategy the umbrella pins rather than against V4. Byte counts are
 * deterministic; MB/s is best of 3 on 16 cores.
 *
 *   S       HiFi vs V4   lowcov vs V5   HiFi MB/s
 *   256 Ki  +6.25%       +31.45%        ~510
 *   512 Ki  +5.84%       +29.82%        ~550
 *   1 Mi    +5.42%       +28.67%        ~530
 *   2 Mi    +5.13%       +27.92%        ~521
 *   8 Mi    +4.87%       +27.16%        ~408
 *
 * 1 Mi beats 256 Ki on both axes and leaves 64 segments in a 64 MiB
 * block. 8 Mi gives up a fifth of the throughput for a quarter point.
 *
 * S is written into the body header and the segmentation derives from
 * it and the read-length table, so streams written before this keep
 * their own S and decode unchanged. */
#define TTIO_V6_DEFAULT_SEG_SYMBOLS (1024u * 1024u)

/* Whole-block coder, including the outer M94Z container. threads <= 1
 * codes sequentially; output bytes are identical for any thread count,
 * because segments are assembled in segment order regardless of the
 * order in which they finish.
 *
 * decode fills read_lengths from the container's read-length table;
 * the caller must size it for n_reads, and n_reads and n_qualities
 * must match the container or the call is rejected. */
int ttio_m94z_v6_encode_seq(const uint8_t *qual, const uint8_t *seq,
                            size_t n_qualities,
                            const uint32_t *read_lengths, size_t n_reads,
                            const ttio_v6_param *pm, uint32_t seg_symbols,
                            int threads, uint8_t *out, size_t *out_len);

int ttio_m94z_v6_encode(const uint8_t *qual, size_t n_qualities,
                        const uint32_t *read_lengths, size_t n_reads,
                        const ttio_v6_param *pm, uint32_t seg_symbols,
                        int threads, uint8_t *out, size_t *out_len);

/* seq is required when the stream's header carries sbits > 0, and
 * ignored otherwise; the width comes from the stream, not the caller. */
int ttio_m94z_v6_decode_seq(const uint8_t *in, size_t in_len,
                            const uint8_t *seq,
                            uint32_t *read_lengths, size_t n_reads,
                            int threads, uint8_t *qual_out,
                            size_t n_qualities);

int ttio_m94z_v6_decode(const uint8_t *in, size_t in_len,
                        uint32_t *read_lengths, size_t n_reads,
                        int threads, uint8_t *qual_out,
                        size_t n_qualities);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_M94Z_V6_H */
