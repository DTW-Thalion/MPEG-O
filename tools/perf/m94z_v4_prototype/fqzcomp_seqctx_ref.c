/* tools/perf/m94z_v4_prototype/fqzcomp_seqctx_ref.c
 *
 * Qualities-V5 bake-off prototype: V4-shaped adaptive quality model
 * (quality history + position + delta context, one SIMPLE_MODEL per
 * context, CRAM range coder) with an optional sequence-context field
 * spliced into the context word. Throwaway measurement code — informs
 * the V5 spec, is not the V5 implementation.
 *
 * Context word layout (low to high):
 *   [ qctx : qbits ][ pos : pbits ][ delta : dbits ][ seq : sbits ]
 * Total bits <= 18 (memory: (1<<bits) * ~1 KB models).
 *
 * Sequence context modes (--seq-mode):
 *   0  off (sbits ignored; the m0 baseline)
 *   1  packed window of the CURRENT base and its predecessors:
 *      seqctx = last (sbits/2) bases, 2 bits each, current included
 *   2  as 1 but predecessors only (current base excluded)
 *   3  multiplicative hash of the last --khash bases folded to sbits
 * Base codes: A=0 C=1 G=2 T=3, anything else (N) = 0.
 *
 * Encodes AND decodes; every run round-trips the full stream and
 * fails hard on mismatch, so a size win cannot come from a model
 * the decoder could not reproduce. The decoder consumes seq.bin as
 * side input, which mirrors the V5 contract (sequences are decoded
 * before qualities; the writer gates V5 on their presence).
 *
 * Compile:
 *   cc -O2 -I tools/perf/htscodecs \
 *      tools/perf/m94z_v4_prototype/fqzcomp_seqctx_ref.c \
 *      -o /tmp/v5bake/fqzcomp_seqctx_ref
 *
 * Usage:
 *   fqzcomp_seqctx_ref qual.bin seq.bin lens.bin \
 *       --qbits N --qshift N --pbits N --pshift N --dbits N \
 *       --sbits N --seq-mode {0,1,2,3} [--khash K]
 * Prints one summary line:
 *   RESULT mode=<m> qbits=.. ... bytes=<n> bq=<b/qual> wall=<s>
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "htscodecs/c_range_coder.h"
#define NSYM 256
#include "htscodecs/c_simple_model.h"

#ifndef MIN
#  define MIN(a,b) ((a)<(b)?(a):(b))
#endif

#define MAX_CTX_BITS 18

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    *len = (size_t)sz;
    uint8_t *buf = malloc(*len ? *len : 1);
    if (buf && *len && fread(buf, 1, *len, f) != *len) { free(buf); buf = NULL; }
    fclose(f);
    return buf;
}

typedef struct {
    int qbits, qshift, pbits, pshift, dbits, dshift;
    int sbits, seq_mode, khash;
} params;

/* base -> 2-bit code; N and anything unexpected -> 0 */
static uint8_t bcode_tab[256];
static void init_bcode(void) {
    memset(bcode_tab, 0, sizeof(bcode_tab));
    bcode_tab['C'] = 1; bcode_tab['G'] = 2; bcode_tab['T'] = 3;
    bcode_tab['c'] = 1; bcode_tab['g'] = 2; bcode_tab['t'] = 3;
}

/* One pass over the whole corpus: encode (do_encode=1) or decode.
 * Returns compressed size (encode) or 0 (decode), negative on error.
 * On decode, qual is the OUTPUT buffer. */
static int64_t code_pass(const params *P,
                         uint8_t *qual, const uint8_t *seq,
                         const uint32_t *lens, size_t n_reads,
                         size_t n_qual,
                         uint8_t *comp, size_t comp_cap,
                         int do_encode)
{
    int ctx_bits = P->qbits + P->pbits + P->dbits +
                   (P->seq_mode ? P->sbits : 0);
    if (ctx_bits > MAX_CTX_BITS) {
        fprintf(stderr, "ctx bits %d > %d\n", ctx_bits, MAX_CTX_BITS);
        return -1;
    }
    size_t n_ctx = (size_t)1 << ctx_bits;
    SIMPLE_MODEL(256,_) *models = malloc(n_ctx * sizeof(*models));
    if (!models) { fprintf(stderr, "OOM models\n"); return -1; }
    for (size_t i = 0; i < n_ctx; i++)
        SIMPLE_MODEL(256,_init)(&models[i], 256);

    const unsigned qmask = (1u << P->qbits) - 1;
    const unsigned smask = P->sbits ? (1u << P->sbits) - 1 : 0;
    const int ploc = P->qbits;
    const int dloc = P->qbits + P->pbits;
    const int xloc = P->qbits + P->pbits + P->dbits;
    const unsigned pmax = (1u << P->pbits) - 1;
    const unsigned dmax = P->dbits ? (1u << P->dbits) - 1 : 0;

    RangeCoder rc;
    if (do_encode) { RC_SetOutput(&rc, (char *)comp); RC_StartEncode(&rc); }
    else           { RC_SetInput(&rc, (char *)comp, (char *)comp + comp_cap);
                     RC_StartDecode(&rc); }

    size_t off = 0;
    for (size_t r = 0; r < n_reads; r++) {
        unsigned qctx = 0, seqctx = 0, delta = 0;
        unsigned prevq = 0;
        uint32_t len = lens[r];
        for (uint32_t i = 0; i < len; i++) {
            size_t k = off + i;
            unsigned sfield = 0;
            if (P->seq_mode == 1) {
                seqctx = ((seqctx << 2) | bcode_tab[seq[k]]) & smask;
                sfield = seqctx;
            } else if (P->seq_mode == 2) {
                sfield = seqctx;      /* predecessors only */
                seqctx = ((seqctx << 2) | bcode_tab[seq[k]]) & smask;
            } else if (P->seq_mode == 3) {
                seqctx = (seqctx << 2) | bcode_tab[seq[k]];
                seqctx &= (1u << (2 * P->khash)) - 1;
                sfield = (unsigned)(((uint64_t)seqctx * 0x9E3779B1u)
                                    >> (32 - P->sbits)) & smask;
            }
            unsigned pos = MIN(pmax, (len - 1 - i) >> P->pshift);
            unsigned dfield = P->dbits ? MIN(dmax, delta >> P->dshift) : 0;
            unsigned ctx = (qctx & qmask)
                         | (pos << ploc)
                         | (dfield << dloc)
                         | (P->seq_mode ? (sfield << xloc) : 0);
            unsigned q;
            if (do_encode) {
                q = qual[k];
                SIMPLE_MODEL(256,_encodeSymbol)(&models[ctx], &rc, (uint16_t)q);
            } else {
                q = SIMPLE_MODEL(256,_decodeSymbol)(&models[ctx], &rc);
                qual[k] = (uint8_t)q;
            }
            qctx = (qctx << P->qshift) + q;
            delta += (prevq != q);
            prevq = q;
        }
        off += len;
    }
    (void)n_qual;

    int64_t out_sz = 0;
    if (do_encode) { RC_FinishEncode(&rc); out_sz = (int64_t)RC_OutSize(&rc); }
    else           { RC_FinishDecode(&rc); }
    free(models);
    return out_sz;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s qual.bin seq.bin lens.bin [params]\n",
                argv[0]);
        return 1;
    }
    init_bcode();
    params P = { .qbits = 8, .qshift = 5, .pbits = 7, .pshift = 0,
                 .dbits = 0, .dshift = 0, .sbits = 0, .seq_mode = 0,
                 .khash = 8 };
    for (int a = 4; a + 1 < argc; a += 2) {
        const char *k = argv[a]; int v = atoi(argv[a + 1]);
        if      (!strcmp(k, "--qbits"))    P.qbits = v;
        else if (!strcmp(k, "--qshift"))   P.qshift = v;
        else if (!strcmp(k, "--pbits"))    P.pbits = v;
        else if (!strcmp(k, "--pshift"))   P.pshift = v;
        else if (!strcmp(k, "--dbits"))    P.dbits = v;
        else if (!strcmp(k, "--dshift"))   P.dshift = v;
        else if (!strcmp(k, "--sbits"))    P.sbits = v;
        else if (!strcmp(k, "--seq-mode")) P.seq_mode = v;
        else if (!strcmp(k, "--khash"))    P.khash = v;
        else { fprintf(stderr, "unknown arg %s\n", k); return 1; }
    }

    size_t n_qual, n_seq, lens_len;
    uint8_t *qual = read_file(argv[1], &n_qual);
    uint8_t *seq  = read_file(argv[2], &n_seq);
    uint8_t *lens_raw = read_file(argv[3], &lens_len);
    if (!qual || !seq || !lens_raw) return 2;
    if (n_seq != n_qual) { fprintf(stderr, "seq/qual length mismatch\n"); return 2; }
    const uint32_t *lens = (const uint32_t *)lens_raw;
    size_t n_reads = lens_len / sizeof(uint32_t);

    size_t comp_cap = n_qual + n_qual / 2 + (1 << 20);
    uint8_t *comp = malloc(comp_cap);
    if (!comp) { fprintf(stderr, "OOM comp\n"); return 2; }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int64_t sz = code_pass(&P, qual, seq, lens, n_reads, n_qual,
                           comp, comp_cap, 1);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (sz < 0) return 3;
    double wall = (double)(t1.tv_sec - t0.tv_sec)
                + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;

    /* Round-trip: decode into a fresh buffer, compare bit-exact. */
    uint8_t *rt = malloc(n_qual ? n_qual : 1);
    if (!rt) { fprintf(stderr, "OOM rt\n"); return 2; }
    if (code_pass(&P, rt, seq, lens, n_reads, n_qual,
                  comp, (size_t)sz, 0) < 0) return 3;
    if (memcmp(rt, qual, n_qual) != 0) {
        fprintf(stderr, "ROUND-TRIP MISMATCH — result invalid\n");
        return 4;
    }

    printf("RESULT mode=%d qbits=%d qshift=%d pbits=%d pshift=%d "
           "dbits=%d dshift=%d sbits=%d khash=%d "
           "bytes=%lld bq=%.4f wall=%.1f rt=ok\n",
           P.seq_mode, P.qbits, P.qshift, P.pbits, P.pshift,
           P.dbits, P.dshift, P.sbits, P.khash,
           (long long)sz, (double)sz / (double)n_qual, wall);
    free(qual); free(seq); free(lens_raw); free(comp); free(rt);
    return 0;
}
