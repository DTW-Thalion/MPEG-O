/*
 * TestImportedDataset — OT1: normalized in-memory importer draft.
 *
 * Verifies TTIOImportedDataset:
 *   (1) non-delegate path writes via
 *       +[TTIOSpectralDataset writeMinimalToPath:...mixedRuns:...] and the
 *       result reopens via +readFromFilePath: with one MS run;
 *   (2) write-through delegate path: when writeDelegate is set, -writeToPath:
 *       calls it instead of the writeMinimal path.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Import/TTIOImportedDataset.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *tmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_imported_%d_%@",
            (int)getpid(), suffix];
}

static TTIOWrittenRun *makeMinimalRun(void)
{
    NSUInteger n = 3, peaks = 4, total = n * peaks;
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

void testImportedDataset(void)
{
    @autoreleasepool {
        // (1) Non-delegate path: build a draft, write, reopen, expect an MS run.
        TTIOImportedDataset *ds = [[TTIOImportedDataset alloc] init];
        ds.title = @"imported title";
        ds.isaInvestigationId = @"INV-1";
        ds.msRuns[@"run_0001"] = makeMinimalRun();

        NSString *outPath = tmpPath(@"writemin.tio");
        NSError *err = nil;
        BOOL ok = [ds writeToPath:outPath error:&err];
        PASS(ok, "TTIOImportedDataset -writeToPath: (writeMinimal path) succeeded");

        TTIOSpectralDataset *reopened =
            [TTIOSpectralDataset readFromFilePath:outPath error:&err];
        PASS(reopened != nil, "reopened written dataset via +readFromFilePath:");
        PASS(reopened.msRuns.count >= 1, "reopened dataset has at least one MS run");
        PASS([reopened.msRuns objectForKey:@"run_0001"] != nil,
             "reopened dataset exposes run_0001");
        [reopened closeFile];
        unlink([outPath fileSystemRepresentation]);

        // (2) Write-through delegate path: -writeToPath: must call the block.
        NSString *delPath = tmpPath(@"delegate.txt");
        TTIOImportedDataset *dds = [[TTIOImportedDataset alloc] init];
        dds.writeDelegate = ^BOOL(NSString *out, NSError **e) {
            return [@"sentinel" writeToFile:out
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:e];
        };
        NSError *derr = nil;
        BOOL dok = [dds writeToPath:delPath error:&derr];
        PASS(dok, "TTIOImportedDataset -writeToPath: (delegate path) succeeded");
        NSString *contents = [NSString stringWithContentsOfFile:delPath
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
        PASS([contents isEqualToString:@"sentinel"],
             "delegate wrote the sentinel file (writeMinimal not used)");
        unlink([delPath fileSystemRepresentation]);
    }
}
