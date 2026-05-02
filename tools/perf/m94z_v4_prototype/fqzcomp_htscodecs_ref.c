/* tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref.c
 *
 * Phase 2 byte-equality gate: htscodecs reference encoder.
 *
 * Encodes a flat-binary qualities buffer with htscodecs's fqz_compress,
 * passing a fully-populated fqz_gparams that matches our Phase 2
 * strategy 1 (HiSeq) parameterization EXACTLY:
 *
 *   gp->vers = FQZ_VERS (5), gflags=0, nparam=1, max_sel=0, max_sym=255
 *   pm->qbits=8 qshift=5 qloc=0 sloc=14 ploc=8 dloc=14
 *   pm->pbits=7 pshift=0 dbits=0 dshift=0 sbits=0
 *   pm->store_qmap=0 do_sel=0 do_dedup=0 do_qa=0 do_r2=0
 *   pm->use_qtab=0 use_ptab=1 use_dtab=0
 *   pm->fixed_len = all-lens-equal-and-nonzero
 *   pm->qmap = identity, pm->qtab = identity
 *   pm->ptab[i] = MIN(127, i>>0)   (since pbits=7, pshift=0)
 *   pm->dtab[*] = 0                (since dbits=0)
 *
 * This bypasses htscodecs's fqz_pick_parameters / fqz_qual_stats
 * auto-tune entirely (we pass gp non-NULL, so fqz_compress uses it
 * verbatim).
 *
 * Compile:
 *   cc -O2 \
 *      -I/home/toddw/TTI-O/tools/perf/htscodecs \
 *      fqzcomp_htscodecs_ref.c \
 *      /home/toddw/TTI-O/tools/perf/htscodecs/htscodecs/.libs/libhtscodecs.a \
 *      -lz -pthread -lm \
 *      -o fqzcomp_htscodecs_ref
 *
 * Usage:
 *   ./fqzcomp_htscodecs_ref qual.bin lens.bin flags.bin out.fqz
 *
 *   qual.bin   : flat uint8 qualities (n bytes)
 *   lens.bin   : uint32[n_reads] per-read lengths
 *   flags.bin  : uint32[n_reads] per-read flags (unused for strategy 1)
 *   out.fqz    : output path
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "htscodecs/fqzcomp_qual.h"

#define MIN(a,b) ((a)<(b)?(a):(b))

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    *len = (size_t)sz;
    uint8_t *buf = (uint8_t *)malloc(*len ? *len : 1);
    if (!buf) { fclose(f); return NULL; }
    if (*len && fread(buf, 1, *len, f) != *len) {
        free(buf); fclose(f); return NULL;
    }
    fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr,
                "usage: %s qual.bin lens.bin flags.bin out.fqz\n", argv[0]);
        return 1;
    }
    const char *qual_path  = argv[1];
    const char *lens_path  = argv[2];
    const char *flags_path = argv[3];
    const char *out_path   = argv[4];

    size_t qual_len = 0, lens_len = 0, flags_len = 0;
    uint8_t *qual_in   = read_file(qual_path,  &qual_len);
    uint8_t *lens_buf  = read_file(lens_path,  &lens_len);
    uint8_t *flags_buf = read_file(flags_path, &flags_len);
    if (!qual_in || !lens_buf || !flags_buf) {
        fprintf(stderr, "read failure\n");
        return 2;
    }

    uint32_t *read_lengths = (uint32_t *)lens_buf;
    uint32_t *flags_u32    = (uint32_t *)flags_buf;
    size_t    n_reads      = lens_len / sizeof(uint32_t);

    fprintf(stderr, "htscodecs ref: %zu qualities, %zu reads\n",
            qual_len, n_reads);

    /* Build fqz_slice */
    fqz_slice s;
    s.num_records = (int)n_reads;
    s.len   = read_lengths;
    s.flags = flags_u32;

    /* Build fqz_gparams matching ttio_fqz_setup_strat1 exactly */
    fqz_gparams gp;
    memset(&gp, 0, sizeof(gp));
    gp.vers     = FQZ_VERS;        /* 5 */
    gp.gflags   = 0;
    gp.nparam   = 1;
    gp.max_sel  = 0;
    gp.max_sym  = 255;             /* mirrors our setup */

    fqz_param *pm = (fqz_param *)calloc(1, sizeof(fqz_param));
    if (!pm) { fprintf(stderr, "OOM pm\n"); return 3; }
    gp.p = pm;

    pm->context = 0;

    /* HiSeq preset, exact values */
    pm->qbits  = 8;
    pm->qshift = 5;
    pm->qloc   = 0;
    pm->sloc   = 14;
    pm->ploc   = 8;
    pm->dloc   = 14;
    pm->pbits  = 7;
    pm->pshift = 0;
    pm->dbits  = 0;
    pm->dshift = 0;
    pm->sbits  = 0;
    pm->qmask  = (1u << pm->qbits) - 1u;

    pm->store_qmap = 0;
    pm->do_sel     = 0;
    pm->do_dedup   = 0;
    pm->do_qa      = 0;
    pm->do_r2      = 0;
    pm->max_sel    = 0;

    /* fixed_len iff all read_lengths are equal AND non-zero */
    {
        int fl = (n_reads > 0);
        for (size_t i = 1; i < n_reads; i++) {
            if (read_lengths[i] != read_lengths[0]) { fl = 0; break; }
        }
        pm->fixed_len = fl;
    }

    pm->use_qtab = 0;
    pm->use_ptab = (pm->pbits > 0);
    pm->use_dtab = (pm->dbits > 0);

    pm->max_sym = 255;
    pm->nsym    = 255;             /* htscodecs sets nsym=255 when !store_qmap */

    /* qmap: identity */
    for (int i = 0; i < 256; i++)
        pm->qmap[i] = (unsigned int)i;

    /* qtab: identity */
    for (int i = 0; i < 256; i++)
        pm->qtab[i] = (unsigned int)i;

    /* ptab: MIN((1<<pbits)-1, i>>pshift) */
    for (int i = 0; i < 1024; i++)
        pm->ptab[i] = (unsigned int)MIN((1<<pm->pbits)-1, i >> pm->pshift);

    /* dtab: dbits=0 -> all zero (htscodecs's dtab[i] = dsqr[...] capped at 0) */
    for (int i = 0; i < 256; i++)
        pm->dtab[i] = 0;

    pm->pflags =
        (pm->use_qtab   ? PFLAG_HAVE_QTAB : 0) |
        (pm->use_dtab   ? PFLAG_HAVE_DTAB : 0) |
        (pm->use_ptab   ? PFLAG_HAVE_PTAB : 0) |
        (pm->do_sel     ? PFLAG_DO_SEL    : 0) |
        (pm->fixed_len  ? PFLAG_DO_LEN    : 0) |
        (pm->do_dedup   ? PFLAG_DO_DEDUP  : 0) |
        (pm->store_qmap ? PFLAG_HAVE_QMAP : 0);

    /* Call fqz_compress with our gp; vers and strat are unused when
     * gp is non-NULL (compress_block_fqz2f only consults vers via
     * fqz_pick_parameters, which is bypassed). Pass vers=4, strat=0. */
    size_t out_size = 0;
    char *out = fqz_compress(/*vers=*/4, &s,
                             (char *)qual_in, qual_len,
                             &out_size, /*strat=*/0, &gp);
    if (!out) {
        fprintf(stderr, "fqz_compress returned NULL\n");
        return 4;
    }
    fprintf(stderr, "htscodecs encoded %zu qualities to %zu bytes\n",
            qual_len, out_size);
    fprintf(stderr, "B/qual = %.4f\n", (double)out_size / (double)qual_len);

    FILE *f = fopen(out_path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", out_path); return 5; }
    if (fwrite(out, 1, out_size, f) != out_size) {
        fclose(f); fprintf(stderr, "short write\n"); return 5;
    }
    fclose(f);
    fprintf(stderr, "wrote to %s\n", out_path);

    free(out);
    free(pm);
    free(qual_in); free(lens_buf); free(flags_buf);
    return 0;
}
