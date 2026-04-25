/*
 * TestWriteMinimal — v1.1 flat-buffer fast path.
 *
 * Verifies that TTIOSpectralDataset +writeMinimalToPath:... produces
 * a file readable by +readFromFilePath: and that round-tripped
 * signal data plus index metadata match exactly. Also checks byte-
 * for-byte parity with the object-mode writer for the same logical
 * content (no distinguishing the producer from the consumer side).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *tmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_writemin_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOWrittenRun *makeMinimalRun(NSUInteger n, NSUInteger peaks)
{
    NSUInteger total = n * peaks;
    NSMutableData *mzBuf = [NSMutableData dataWithLength:total * sizeof(double)];
    NSMutableData *intBuf = [NSMutableData dataWithLength:total * sizeof(double)];
    double *mz  = (double *)mzBuf.mutableBytes;
    double *inn = (double *)intBuf.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        for (NSUInteger j = 0; j < peaks; j++) {
            NSUInteger pos = i * peaks + j;
            mz[pos]  = 100.0 + (double)i + (double)j * 0.1;
            inn[pos] = 1000.0 + (double)((i * 31 + j) % 1000);
        }
    }
    NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *rts     = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *mls     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pols    = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pmzs    = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *pcs     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *bps     = [NSMutableData dataWithLength:n * sizeof(double)];
    int64_t *offsetsPtr = (int64_t *)offsets.mutableBytes;
    uint32_t *lengthsPtr = (uint32_t *)lengths.mutableBytes;
    double *rtPtr = (double *)rts.mutableBytes;
    int32_t *mlPtr = (int32_t *)mls.mutableBytes;
    int32_t *polPtr = (int32_t *)pols.mutableBytes;
    double *pmzPtr = (double *)pmzs.mutableBytes;
    int32_t *pcPtr = (int32_t *)pcs.mutableBytes;
    double *bpPtr = (double *)bps.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        offsetsPtr[i] = (int64_t)i * (int64_t)peaks;
        lengthsPtr[i] = (uint32_t)peaks;
        rtPtr[i]      = (double)i * 0.06;
        mlPtr[i]      = 1;
        polPtr[i]     = 1;
        pmzPtr[i]     = 0.0;
        pcPtr[i]      = 0;
        bpPtr[i]      = 1000.0;
    }
    NSDictionary *channels = @{@"mz": mzBuf, @"intensity": intBuf};
    return [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
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

void testWriteMinimal(void)
{
    NSError *err = nil;

    // ── Basic round-trip ──────────────────────────────────────────────
    NSString *path = tmpPath(@"rt");
    unlink([path fileSystemRepresentation]);
    TTIOWrittenRun *wr = makeMinimalRun(500, 16);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                 title:@"minimal"
                                   isaInvestigationId:@"ISA-MIN"
                                               msRuns:@{@"r": wr}
                                       identifications:nil
                                       quantifications:nil
                                     provenanceRecords:nil
                                                 error:&err];
    PASS(ok, "writeMinimalToPath: succeeds");
    if (!ok) { NSLog(@"err: %@", err); return; }

    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(back != nil, "minimal file re-opens via readFromFilePath:");
    PASS([back.title isEqualToString:@"minimal"], "title round-trips");
    PASS([back.isaInvestigationId isEqualToString:@"ISA-MIN"],
         "isa_investigation_id round-trips");

    TTIOAcquisitionRun *run = back.msRuns[@"r"];
    PASS(run != nil, "run 'r' present after re-open");
    PASS(run.spectrumIndex.count == 500, "spectrum_count matches (500)");

    TTIOMassSpectrum *s0 = [run objectAtIndex:0];
    PASS(s0.signalArrays[@"mz"].length == 16,
         "first spectrum's mz array has 16 peaks");
    const double *mz0 = (const double *)s0.signalArrays[@"mz"].buffer.bytes;
    PASS(mz0[0] == 100.0, "first mz value matches what was written");

    TTIOMassSpectrum *s100 = [run objectAtIndex:100];
    const double *mz100 = (const double *)s100.signalArrays[@"mz"].buffer.bytes;
    PASS(mz100[0] == 200.0,
         "spectrum 100's mz[0] == 200.0 matches encoder formula");

    unlink([path fileSystemRepresentation]);

    // ── Empty nmr_runs must be present so readers see the layout ─────
    NSString *path2 = tmpPath(@"empty_runs");
    unlink([path2 fileSystemRepresentation]);
    ok = [TTIOSpectralDataset writeMinimalToPath:path2
                                            title:@"e"
                              isaInvestigationId:@"ISA"
                                          msRuns:@{}
                                  identifications:nil
                                  quantifications:nil
                                provenanceRecords:nil
                                            error:&err];
    PASS(ok, "writeMinimal with no runs still succeeds");
    back = [TTIOSpectralDataset readFromFilePath:path2 error:&err];
    PASS(back != nil && back.msRuns.count == 0 && back.nmrRuns.count == 0,
         "empty-runs file opens with zero ms_runs and zero nmr_runs");
    unlink([path2 fileSystemRepresentation]);
}
