/*
 * Pure-C libhdf5 harness — same workload as profile_python.py /
 * ProfileHarness.java / profile_objc.m, but bypassing every
 * language binding so we see libhdf5's own floor. If ObjC is
 * significantly slower than this, the TTIOHDF5 wrapper is
 * overhead; if not, ObjC is already at the native floor and the
 * remaining cross-language variance is JHDF5 vs direct-link noise.
 *
 * Matches v1.1 writeMinimal layout: root feature-flag attrs +
 * /study + /study/ms_runs + per-run instrument_config + spectrum_index
 * (8 chunked+zlib datasets) + signal_channels (2 chunked+zlib).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <hdf5.h>

static double nowSec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void set_str_attr(hid_t obj, const char *name, const char *val)
{
    hid_t sp = H5Screate(H5S_SCALAR);
    hid_t tp = H5Tcopy(H5T_C_S1);
    size_t n = strlen(val);
    H5Tset_size(tp, n > 0 ? n : 1);
    H5Tset_strpad(tp, H5T_STR_NULLPAD);
    hid_t aid = H5Acreate2(obj, name, tp, sp, H5P_DEFAULT, H5P_DEFAULT);
    H5Awrite(aid, tp, val);
    H5Aclose(aid); H5Tclose(tp); H5Sclose(sp);
}

static void set_i64_attr(hid_t obj, const char *name, long long v)
{
    hid_t sp = H5Screate(H5S_SCALAR);
    hid_t aid = H5Acreate2(obj, name, H5T_STD_I64LE, sp, H5P_DEFAULT, H5P_DEFAULT);
    H5Awrite(aid, H5T_NATIVE_LLONG, &v);
    H5Aclose(aid); H5Sclose(sp);
}

static void write_compressed(hid_t parent, const char *name,
                              hid_t htype, size_t elem_size,
                              const void *data, hsize_t n,
                              hsize_t chunk)
{
    hsize_t dims[1] = { n };
    hid_t sp = H5Screate_simple(1, dims, NULL);
    hid_t pl = H5Pcreate(H5P_DATASET_CREATE);
    if (chunk > 0 && n > 0) {
        hsize_t c[1] = { chunk < n ? chunk : n };
        H5Pset_chunk(pl, 1, c);
        H5Pset_deflate(pl, 6);
    }
    hid_t did = H5Dcreate2(parent, name, htype, sp,
                           H5P_DEFAULT, pl, H5P_DEFAULT);
    H5Dwrite(did, htype, H5S_ALL, H5S_ALL, H5P_DEFAULT, data);
    H5Dclose(did); H5Pclose(pl); H5Sclose(sp);
    (void)elem_size;
}

static void workload(const char *path, size_t n, size_t peaks,
                      double out_t[3])
{
    size_t total = n * peaks;

    // ── build ─────────────────────────────────────────────
    double t0 = nowSec();
    double   *mz       = malloc(total * sizeof(double));
    double   *inten    = malloc(total * sizeof(double));
    long long *offsets = malloc(n * sizeof(long long));
    unsigned int *lengths = malloc(n * sizeof(unsigned int));
    double   *rts      = malloc(n * sizeof(double));
    int      *mls      = malloc(n * sizeof(int));
    int      *pols     = malloc(n * sizeof(int));
    double   *pmzs     = malloc(n * sizeof(double));
    int      *pcs      = malloc(n * sizeof(int));
    double   *bps      = malloc(n * sizeof(double));
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < peaks; j++) {
            size_t pos = i * peaks + j;
            mz[pos]    = 100.0 + (double)i + (double)j * 0.1;
            inten[pos] = 1000.0 + (double)((i * 31 + j) % 1000);
        }
        offsets[i] = (long long)i * (long long)peaks;
        lengths[i] = (unsigned)peaks;
        rts[i]     = (double)i * 0.06;
        mls[i]     = 1; pols[i] = 1; pmzs[i] = 0.0; pcs[i] = 0; bps[i] = 1000.0;
    }
    out_t[0] = nowSec() - t0;

    // ── write ─────────────────────────────────────────────
    t0 = nowSec();
    hid_t f = H5Fcreate(path, H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);

    // Feature-flag attrs on root (simplified — just 3 representative ones)
    set_str_attr(f, "format_version", "1.1");
    set_str_attr(f, "features", "base_v1,compound_identifications,compound_provenance");

    hid_t study = H5Gcreate2(f, "study", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    set_str_attr(study, "title", "stress");
    set_str_attr(study, "isa_investigation_id", "ISA-STRESS");

    hid_t ms_runs = H5Gcreate2(study, "ms_runs", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    set_str_attr(ms_runs, "_run_names", "r");

    hid_t run = H5Gcreate2(ms_runs, "r", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    set_i64_attr(run, "acquisition_mode", 0);
    set_i64_attr(run, "spectrum_count", (long long)n);
    set_str_attr(run, "spectrum_class", "TTIOMassSpectrum");

    hid_t cfg = H5Gcreate2(run, "instrument_config", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    set_str_attr(cfg, "manufacturer", "");
    set_str_attr(cfg, "model", "");
    set_str_attr(cfg, "serial_number", "");
    set_str_attr(cfg, "source_type", "");
    set_str_attr(cfg, "analyzer_type", "");
    set_str_attr(cfg, "detector_type", "");
    H5Gclose(cfg);

    hid_t idx = H5Gcreate2(run, "spectrum_index", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    set_i64_attr(idx, "count", (long long)n);
    write_compressed(idx, "offsets",           H5T_STD_I64LE,  8, offsets, n, 4096);
    write_compressed(idx, "lengths",           H5T_STD_U32LE,  4, lengths, n, 4096);
    write_compressed(idx, "retention_times",   H5T_IEEE_F64LE, 8, rts,     n, 4096);
    write_compressed(idx, "ms_levels",         H5T_STD_I32LE,  4, mls,     n, 4096);
    write_compressed(idx, "polarities",        H5T_STD_I32LE,  4, pols,    n, 4096);
    write_compressed(idx, "precursor_mzs",     H5T_IEEE_F64LE, 8, pmzs,    n, 4096);
    write_compressed(idx, "precursor_charges", H5T_STD_I32LE,  4, pcs,     n, 4096);
    write_compressed(idx, "base_peak_intensities", H5T_IEEE_F64LE, 8, bps, n, 4096);
    H5Gclose(idx);

    hid_t ch = H5Gcreate2(run, "signal_channels", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    set_str_attr(ch, "channel_names", "mz,intensity");
    write_compressed(ch, "mz_values",         H5T_IEEE_F64LE, 8, mz,    total, 65536);
    write_compressed(ch, "intensity_values",  H5T_IEEE_F64LE, 8, inten, total, 65536);
    H5Gclose(ch);

    H5Gclose(run); H5Gclose(ms_runs);
    hid_t nmr = H5Gcreate2(study, "nmr_runs", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    set_str_attr(nmr, "_run_names", "");
    H5Gclose(nmr); H5Gclose(study); H5Fclose(f);
    out_t[1] = nowSec() - t0;

    // ── read (sampled) ─────────────────────────────────────
    t0 = nowSec();
    hid_t rf = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t rmz = H5Dopen2(rf, "study/ms_runs/r/signal_channels/mz_values", H5P_DEFAULT);
    hid_t rspace = H5Dget_space(rmz);
    hid_t mspace = H5Screate_simple(1, (hsize_t[]){peaks}, NULL);
    double buf[128];
    size_t sampled = 0;
    for (size_t i = 0; i < n; i += 100) {
        hsize_t start[1] = { i * peaks };
        hsize_t cnt[1]   = { peaks };
        H5Sselect_hyperslab(rspace, H5S_SELECT_SET, start, NULL, cnt, NULL);
        H5Dread(rmz, H5T_NATIVE_DOUBLE, mspace, rspace, H5P_DEFAULT, buf);
        sampled += peaks;
    }
    H5Sclose(mspace); H5Sclose(rspace);
    H5Dclose(rmz); H5Fclose(rf);
    out_t[2] = nowSec() - t0;

    size_t expected = ((n + 99) / 100) * peaks;
    if (sampled != expected) {
        fprintf(stderr, "sampled=%zu expected=%zu\n", sampled, expected);
        exit(1);
    }

    free(mz); free(inten); free(offsets); free(lengths); free(rts);
    free(mls); free(pols); free(pmzs); free(pcs); free(bps);
}

int main(int argc, char **argv)
{
    size_t n = 10000;
    size_t peaks = 16;
    int warmups = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--n") && i + 1 < argc)        n = atol(argv[++i]);
        else if (!strcmp(argv[i], "--peaks") && i+1 < argc) peaks = atol(argv[++i]);
        else if (!strcmp(argv[i], "--warmups") && i+1<argc) warmups = atoi(argv[++i]);
    }

    char path[512];
    snprintf(path, sizeof(path), "%s/mpgo_profile_rawc_out/stress.tio",
             getenv("HOME") ? getenv("HOME") : "/tmp");
    char dir[512];
    snprintf(dir, sizeof(dir), "%s/mpgo_profile_rawc_out",
             getenv("HOME") ? getenv("HOME") : "/tmp");
    char mkcmd[600];
    snprintf(mkcmd, sizeof(mkcmd), "mkdir -p %s", dir);
    if (system(mkcmd) != 0) return 1;

    for (int w = 0; w < warmups; w++) {
        double t[3];
        workload(path, n, peaks, t);
        remove(path);
    }

    double t[3];
    workload(path, n, peaks, t);

    struct stat { off_t size; };
    FILE *fp = fopen(path, "rb");
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fclose(fp);

    printf("==============================================================================\n");
    printf("Raw-C profile: n=%zu, peaks=%zu, file=%.2f MB, warmups=%d\n",
           n, peaks, size / 1e6, warmups);
    printf("==============================================================================\n");
    printf("  phase build     : %8.1f ms\n", t[0] * 1000.0);
    printf("  phase write     : %8.1f ms\n", t[1] * 1000.0);
    printf("  phase read      : %8.1f ms\n", t[2] * 1000.0);
    printf("  phase TOTAL     : %8.1f ms\n", (t[0]+t[1]+t[2]) * 1000.0);
    return 0;
}
