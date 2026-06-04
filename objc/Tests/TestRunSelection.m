/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * OT3: TTIORunSelection — analytical / NMR / genomic run selection by
 *      optional layer name. ObjC port of Python ttio.exporters._select
 *      (analytical_run / nmr_run / genomic_run) and Java RunSelection.
 *      Error-message strings are kept byte-identical to Python so
 *      cross-language error parity holds.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Export/TTIORunSelection.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Run/TTIOAcquisitionRun.h"
#import "ValueClasses/TTIOEnums.h"


static NSString *rsTmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_runsel_%d_%@",
            (int)getpid(), suffix];
}

static TTIOWrittenRun *rsMakeRun(NSString *spectrumClass)
{
    NSUInteger n = 2, peaks = 3, total = n * peaks;
    NSMutableData *mzBuf  = [NSMutableData dataWithLength:total * sizeof(double)];
    NSMutableData *intBuf = [NSMutableData dataWithLength:total * sizeof(double)];
    double *mz  = (double *)mzBuf.mutableBytes;
    double *inn = (double *)intBuf.mutableBytes;
    for (NSUInteger i = 0; i < total; i++) { mz[i] = 100.0 + (double)i; inn[i] = 1000.0; }

    NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *rts     = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *mls     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pols    = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pmzs    = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *pcs     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *bps     = [NSMutableData dataWithLength:n * sizeof(double)];
    int64_t  *offsetsPtr = (int64_t *)offsets.mutableBytes;
    uint32_t *lengthsPtr = (uint32_t *)lengths.mutableBytes;
    double   *rtPtr  = (double *)rts.mutableBytes;
    int32_t  *mlPtr  = (int32_t *)mls.mutableBytes;
    int32_t  *polPtr = (int32_t *)pols.mutableBytes;
    double   *pmzPtr = (double *)pmzs.mutableBytes;
    int32_t  *pcPtr  = (int32_t *)pcs.mutableBytes;
    double   *bpPtr  = (double *)bps.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        offsetsPtr[i] = (int64_t)i * (int64_t)peaks;
        lengthsPtr[i] = (uint32_t)peaks;
        rtPtr[i]  = (double)i * 0.06;
        mlPtr[i]  = 1; polPtr[i] = 1; pmzPtr[i] = 0.0; pcPtr[i] = 0; bpPtr[i] = 1000.0;
    }
    NSDictionary *channels = @{@"mz": mzBuf, @"intensity": intBuf};
    return [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:spectrumClass
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:channels
                          offsets:offsets
                          lengths:lengths
                   retentionTimes:rts
                         msLevels:mls
                       polarities:pols
                     precursorMzs:pmzs
                 precursorCharges:pcs
              basePeakIntensities:bps];
}

/* Write `runs` (name -> TTIOWrittenRun) and reopen, returning the
 * read-side dataset (or nil on failure). */
static TTIOSpectralDataset *rsBuildDataset(NSDictionary *runs, NSString *suffix)
{
    NSString *path = rsTmpPath(suffix);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                title:@"runsel"
                                   isaInvestigationId:@"inv"
                                               msRuns:runs
                                      identifications:nil
                                      quantifications:nil
                                    provenanceRecords:nil
                                                error:&err];
    if (!ok) {
        fprintf(stderr, "rsBuildDataset write failed: %s\n",
                err.localizedDescription.UTF8String);
        return nil;
    }
    return [TTIOSpectralDataset readFromFilePath:path error:&err];
}


void testRunSelection(void)
{
    @autoreleasepool {
        // ---- Two MS runs: layer selects the named run -----------------
        TTIOSpectralDataset *two =
            rsBuildDataset(@{@"run_a": rsMakeRun(@"TTIOMassSpectrum"),
                             @"run_b": rsMakeRun(@"TTIOMassSpectrum")},
                           @"two.tio");
        PASS(two != nil, "OT3: two-run dataset reopens");
        PASS(two.msRuns.count == 2, "OT3: dataset exposes two MS runs");

        NSError *err = nil;
        TTIOAcquisitionRun *picked =
            [TTIORunSelection analyticalRunIn:two layer:@"run_b" error:&err];
        PASS(picked != nil, "OT3: analyticalRunIn:layer: returns named run");
        PASS([picked.name isEqualToString:@"run_b"],
             "OT3: returned run is the one named by layer");

        // ---- nil layer + ambiguous: nil + Python error message --------
        err = nil;
        TTIOAcquisitionRun *amb =
            [TTIORunSelection analyticalRunIn:two layer:nil error:&err];
        PASS(amb == nil, "OT3: nil layer with two runs returns nil");
        PASS(err != nil && [err.localizedDescription
                isEqualToString:@"multiple runs present; pass --layer <name>"],
             "OT3: ambiguous error mirrors Python string");

        // ---- Unknown layer: nil + 'not found; have:' (sorted) ---------
        err = nil;
        TTIOAcquisitionRun *missing =
            [TTIORunSelection analyticalRunIn:two layer:@"nope" error:&err];
        PASS(missing == nil, "OT3: unknown layer returns nil");
        PASS(err != nil && [err.localizedDescription
                isEqualToString:@"run 'nope' not found; have: run_a, run_b"],
             "OT3: not-found error mirrors Python string (sorted names)");

        // ---- Sole run: returned without a layer -----------------------
        TTIOSpectralDataset *one =
            rsBuildDataset(@{@"only": rsMakeRun(@"TTIOMassSpectrum")},
                           @"one.tio");
        PASS(one != nil, "OT3: one-run dataset reopens");
        err = nil;
        TTIOAcquisitionRun *sole =
            [TTIORunSelection analyticalRunIn:one layer:nil error:&err];
        PASS(sole != nil && [sole.name isEqualToString:@"only"],
             "OT3: sole run returned without a layer");

        // ---- Empty dataset: nil + 'no analytical runs' ----------------
        TTIOSpectralDataset *none = rsBuildDataset(@{}, @"none.tio");
        PASS(none != nil, "OT3: empty dataset reopens");
        err = nil;
        TTIOAcquisitionRun *empty =
            [TTIORunSelection analyticalRunIn:none layer:nil error:&err];
        PASS(empty == nil, "OT3: empty dataset returns nil");
        PASS(err != nil && [err.localizedDescription
                isEqualToString:@"no analytical runs in dataset"],
             "OT3: empty-dataset error mirrors Python string");

        // ---- nmrRunIn: prefers NMR-classed run; sole fallback ---------
        TTIOSpectralDataset *mixed =
            rsBuildDataset(@{@"ms_run":  rsMakeRun(@"TTIOMassSpectrum"),
                             @"nmr_run": rsMakeRun(@"TTIONMRSpectrum")},
                           @"mixed.tio");
        PASS(mixed != nil, "OT3: mixed MS+NMR dataset reopens");
        err = nil;
        TTIOAcquisitionRun *nmr =
            [TTIORunSelection nmrRunIn:mixed layer:nil error:&err];
        PASS(nmr != nil && [nmr.name isEqualToString:@"nmr_run"],
             "OT3: nmrRunIn: prefers the NMR-classed run");
    }
}
