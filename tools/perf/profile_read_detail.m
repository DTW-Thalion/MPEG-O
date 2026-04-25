/*
 * Read-path breakdown harness — isolates each fixed per-call cost in
 * TTIOHDF5Dataset readDataAtOffset. Measures:
 *
 *   A. Raw C H5Dread (baseline)
 *   B. ObjC readDataAtOffset: (the library call actually used)
 *   C. Just spectrumAtIndex: (full object-mode read incl MassSpectrum alloc)
 *
 * Workload: 100K 16-peak spectra, sample 1000. Same as profile_objc.m
 * in object mode, but instrumented for per-phase attribution.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import <time.h>
#import <hdf5.h>

#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "ValueClasses/TTIOEnums.h"

static double nowSec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static TTIOWrittenRun *minimalRun(NSUInteger n, NSUInteger peaks) {
    NSUInteger total = n * peaks;
    NSMutableData *mzBuf  = [NSMutableData dataWithLength:total * sizeof(double)];
    NSMutableData *intBuf = [NSMutableData dataWithLength:total * sizeof(double)];
    double *mz = mzBuf.mutableBytes, *in_ = intBuf.mutableBytes;
    for (NSUInteger i = 0; i < n; i++)
        for (NSUInteger j = 0; j < peaks; j++) {
            NSUInteger pos = i*peaks+j;
            mz[pos]  = 100.0 + (double)i + (double)j * 0.1;
            in_[pos] = 1000.0 + (double)((i*31 + j) % 1000);
        }
    NSMutableData *off = [NSMutableData dataWithLength:n*8];
    NSMutableData *len = [NSMutableData dataWithLength:n*4];
    NSMutableData *rts = [NSMutableData dataWithLength:n*8];
    NSMutableData *ml  = [NSMutableData dataWithLength:n*4];
    NSMutableData *pol = [NSMutableData dataWithLength:n*4];
    NSMutableData *pmz = [NSMutableData dataWithLength:n*8];
    NSMutableData *pc  = [NSMutableData dataWithLength:n*4];
    NSMutableData *bp  = [NSMutableData dataWithLength:n*8];
    int64_t *op = off.mutableBytes; uint32_t *lp = len.mutableBytes;
    double *rp = rts.mutableBytes; int32_t *mp = ml.mutableBytes;
    int32_t *pp = pol.mutableBytes; double *qp = pmz.mutableBytes;
    int32_t *cp = pc.mutableBytes; double *bpp = bp.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        op[i] = (int64_t)(i*peaks); lp[i] = (uint32_t)peaks;
        rp[i] = (double)i*0.06; mp[i] = 1; pp[i] = 1;
        qp[i] = 0.0; cp[i] = 0; bpp[i] = 1000.0;
    }
    return [[TTIOWrittenRun alloc] initWithSpectrumClassName:@"TTIOMassSpectrum"
        acquisitionMode:0 channelData:@{@"mz":mzBuf, @"intensity":intBuf}
        offsets:off lengths:len retentionTimes:rts msLevels:ml
        polarities:pol precursorMzs:pmz precursorCharges:pc basePeakIntensities:bp];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSUInteger n = 100000;
        NSUInteger peaks = 16;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--n") && i+1 < argc) n = atol(argv[++i]);
        }

        const char *home = getenv("HOME");
        NSString *path = [NSString stringWithFormat:@"%s/mpgo_readdetail_out/stress.tio",
                          home ? home : "/tmp"];
        NSString *dir = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        unlink([path fileSystemRepresentation]);

        // write fixture
        NSError *err = nil;
        [TTIOSpectralDataset writeMinimalToPath:path title:@"s"
                             isaInvestigationId:@"I" msRuns:@{@"r": minimalRun(n, peaks)}
                                 identifications:nil quantifications:nil
                               provenanceRecords:nil error:&err];

        // warm up
        for (int w = 0; w < 2; w++) {
            TTIOSpectralDataset *d = [TTIOSpectralDataset readFromFilePath:path error:&err];
            TTIOAcquisitionRun *r = d.msRuns[@"r"];
            for (NSUInteger i = 0; i < n; i += 100) (void)[r objectAtIndex:i];
        }

        NSUInteger stride = 100;
        NSUInteger samples = (n + stride - 1) / stride;

        printf("============================================================\n");
        printf("Read-path breakdown: n=%lu, peaks=%lu, samples=%lu\n",
               (unsigned long)n, (unsigned long)peaks, (unsigned long)samples);
        printf("============================================================\n");

        // ── A. RAW C H5Dread, reusing memspace+filespace ───────────
        hid_t f = H5Fopen([path UTF8String], H5F_ACC_RDONLY, H5P_DEFAULT);
        hid_t mzds = H5Dopen2(f, "study/ms_runs/r/signal_channels/mz_values", H5P_DEFAULT);
        hid_t fspace = H5Dget_space(mzds);
        hsize_t cnt[1] = { peaks };
        hid_t mspace = H5Screate_simple(1, cnt, NULL);
        double buf[128];
        double t = nowSec();
        for (NSUInteger i = 0; i < n; i += stride) {
            hsize_t start[1] = { i * peaks };
            H5Sselect_hyperslab(fspace, H5S_SELECT_SET, start, NULL, cnt, NULL);
            H5Dread(mzds, H5T_NATIVE_DOUBLE, mspace, fspace, H5P_DEFAULT, buf);
        }
        double rawC = nowSec() - t;
        H5Sclose(mspace); H5Sclose(fspace); H5Dclose(mzds); H5Fclose(f);
        printf("A. raw C (1 channel, reuse spaces)  : %8.2f ms  (%6.1f us/call)\n",
               rawC*1000, rawC*1e6/samples);

        // ── B. TTIOHDF5Dataset readDataAtOffset, 1 channel ─────────
        TTIOHDF5File *file = [TTIOHDF5File openAtPath:path error:&err];
        TTIOHDF5Group *root = [file rootGroup];
        TTIOHDF5Group *study = [root openGroupNamed:@"study" error:NULL];
        TTIOHDF5Group *msr = [study openGroupNamed:@"ms_runs" error:NULL];
        TTIOHDF5Group *rg = [msr openGroupNamed:@"r" error:NULL];
        TTIOHDF5Group *sc = [rg openGroupNamed:@"signal_channels" error:NULL];
        TTIOHDF5Dataset *mzd = [sc openDatasetNamed:@"mz_values" error:NULL];
        t = nowSec();
        for (NSUInteger i = 0; i < n; i += stride) {
            NSData *d = [mzd readDataAtOffset:i*peaks count:peaks error:NULL];
            (void)d;
        }
        double objDS = nowSec() - t;
        printf("B. TTIOHDF5Dataset 1ch (current)    : %8.2f ms  (%6.1f us/call)\n",
               objDS*1000, objDS*1e6/samples);

        // ── B2. Same but reusing spaces+htype MANUALLY via H5 calls ─
        hid_t mzd2 = [mzd datasetId];
        hid_t fs2 = H5Dget_space(mzd2);
        hid_t ms2 = H5Screate_simple(1, cnt, NULL);
        t = nowSec();
        for (NSUInteger i = 0; i < n; i += stride) {
            hsize_t start[1] = { i * peaks };
            H5Sselect_hyperslab(fs2, H5S_SELECT_SET, start, NULL, cnt, NULL);
            double stackbuf[128];
            H5Dread(mzd2, H5T_NATIVE_DOUBLE, ms2, fs2, H5P_DEFAULT, stackbuf);
        }
        double objReuse = nowSec() - t;
        H5Sclose(fs2); H5Sclose(ms2);
        printf("B2. via dataset handle, reuse spaces: %8.2f ms  (%6.1f us/call)\n",
               objReuse*1000, objReuse*1e6/samples);

        // Measure per-array cost inside spectrum_index to quantify
        // the savings potential of lazy-loading the 6 non-random-access
        // arrays (ms_levels etc — only needed for RT/level filter ops).
        hid_t fidx = H5Fopen([path UTF8String], H5F_ACC_RDONLY, H5P_DEFAULT);
        const char *idxNames[] = {
            "study/ms_runs/r/spectrum_index/offsets",
            "study/ms_runs/r/spectrum_index/lengths",
            "study/ms_runs/r/spectrum_index/retention_times",
            "study/ms_runs/r/spectrum_index/ms_levels",
            "study/ms_runs/r/spectrum_index/polarities",
            "study/ms_runs/r/spectrum_index/precursor_mzs",
            "study/ms_runs/r/spectrum_index/precursor_charges",
            "study/ms_runs/r/spectrum_index/base_peak_intensities",
        };
        double perArr[8];
        for (int a = 0; a < 8; a++) {
            double tt = nowSec();
            hid_t d = H5Dopen2(fidx, idxNames[a], H5P_DEFAULT);
            hid_t dt = H5Dget_type(d);
            size_t es = H5Tget_size(dt);
            void *buf2 = malloc(n * es);
            H5Dread(d, dt, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf2);
            H5Tclose(dt); H5Dclose(d); free(buf2);
            perArr[a] = nowSec() - tt;
        }
        H5Fclose(fidx);
        double lazySavings = 0;
        for (int a = 2; a < 8; a++) lazySavings += perArr[a];
        printf("\n== spectrum_index per-array cost ==\n");
        const char *short_[] = {"offsets", "lengths", "retention_times",
            "ms_levels", "polarities", "precursor_mzs",
            "precursor_charges", "base_peak_intensities"};
        for (int a = 0; a < 8; a++) {
            printf("  %-25s : %5.2f ms%s\n", short_[a], perArr[a]*1000,
                   a < 2 ? "  (REQUIRED — random access)"
                         : "  (LAZY candidate — query-only)");
        }
        printf("  lazy-candidate total        : %5.2f ms  <- potential savings\n",
               lazySavings*1000);

        // ── C0. readFromFilePath: in isolation (opens file, loads
        //         all 8 spectrum_index arrays, but no spectrum reads)
        t = nowSec();
        TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
        double openC = nowSec() - t;
        printf("\nC0. readFromFilePath (alone)        : %8.2f ms\n", openC*1000);

        TTIOAcquisitionRun *run = ds.msRuns[@"r"];
        t = nowSec();
        NSUInteger sampled = 0;
        for (NSUInteger i = 0; i < n; i += stride) {
            TTIOMassSpectrum *s = [run objectAtIndex:i];
            sampled += s.signalArrays[@"mz"].length;
        }
        double full = nowSec() - t;
        printf("C1. spectrumAtIndex loop alone      : %8.2f ms  (%6.1f us/call)\n",
               full*1000, full*1e6/samples);
        printf("C.  total (C0 + C1) — matches bench : %8.2f ms\n",
               (openC+full)*1000);
        (void)sampled;

        printf("\n== Per-call cost breakdown ==\n");
        printf("  raw C H5Dread (1ch)            : %6.1f us\n", rawC*1e6/samples);
        printf("  TTIOHDF5Dataset readDataAtOffset: %6.1f us  (+%.1f us wrapper)\n",
               objDS*1e6/samples, (objDS-rawC)*1e6/samples);
        printf("  handle-level reuse spaces      : %6.1f us  (best-case H5Dread)\n",
               objReuse*1e6/samples);
        printf("  full objectAtIndex (2ch+obj)   : %6.1f us  (2ch + alloc)\n",
               full*1e6/samples);

        printf("\n== Where the 21ms gap comes from ==\n");
        printf("  readFromFilePath: %5.1f ms  (spectrum_index: 8 arrays, loaded eagerly)\n",
               openC*1000);
        printf("  sampling loop  : %5.1f ms  (1000 reads × 2 channels + object alloc)\n",
               full*1000);
        printf("  raw C baseline : %5.1f ms  (1000 reads × 1 channel, direct)\n",
               rawC*1000);
    }
    return 0;
}
