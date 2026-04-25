/*
 * TestAcquisitionSimulator — v0.10 M69.
 *
 * Within-language determinism + AU-shape + materialization.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Transport/TTIOAcquisitionSimulator.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOAccessUnit.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"

static NSString *tmp(NSString *name)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m69_%d_%@",
            (int)getpid(), name];
}

static void rm(NSString *p) { [[NSFileManager defaultManager] removeItemAtPath:p error:NULL]; }

static NSUInteger countAUs(NSArray<TTIOTransportPacketRecord *> *packets)
{
    NSUInteger n = 0;
    for (TTIOTransportPacketRecord *r in packets) {
        if (r.header.packetType == TTIOTransportPacketAccessUnit) n++;
    }
    return n;
}

void testAcquisitionSimulator(void)
{
    // ── 1. Scan count ─────────────────────────────────────────────
    {
        NSMutableData *buf = [NSMutableData data];
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
        TTIOAcquisitionSimulator *sim =
            [[TTIOAcquisitionSimulator alloc]
                initWithScanRate:10.0 duration:2.0 ms1Fraction:0.3
                           mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:1];
        NSError *err = nil;
        NSUInteger n = [sim streamToWriter:tw error:&err];
        [tw close];
        PASS(n == 20, "simulator emits scan_rate * duration AUs");

        TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:buf];
        NSArray<TTIOTransportPacketRecord *> *packets =
            [tr readAllPacketsWithError:&err];
        PASS(packets != nil, "simulator output parses cleanly");
        PASS(countAUs(packets) == 20, "20 AU packets in stream");
    }

    // ── 2. Deterministic under same seed ───────────────────────────
    {
        NSMutableData *a = [NSMutableData data], *b = [NSMutableData data];
        NSError *err = nil;
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:a];
        [[[TTIOAcquisitionSimulator alloc]
             initWithScanRate:5.0 duration:1.0 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:42]
            streamToWriter:tw error:&err];
        [tw close];

        tw = [[TTIOTransportWriter alloc] initWithMutableData:b];
        [[[TTIOAcquisitionSimulator alloc]
             initWithScanRate:5.0 duration:1.0 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:42]
            streamToWriter:tw error:&err];
        [tw close];

        // Parse both into packet records; compare payloads
        // (timestamps differ per packet).
        TTIOTransportReader *trA = [[TTIOTransportReader alloc] initWithData:a];
        TTIOTransportReader *trB = [[TTIOTransportReader alloc] initWithData:b];
        NSArray *pa = [trA readAllPacketsWithError:&err];
        NSArray *pb = [trB readAllPacketsWithError:&err];
        BOOL equal = (pa.count == pb.count);
        if (equal) {
            for (NSUInteger i = 0; i < pa.count && equal; i++) {
                TTIOTransportPacketRecord *ra = pa[i];
                TTIOTransportPacketRecord *rb = pb[i];
                if (![ra.payload isEqualToData:rb.payload]) { equal = NO; break; }
            }
        }
        PASS(equal, "same seed → identical AU payloads");
    }

    // ── 3. Different seeds differ ──────────────────────────────────
    {
        NSMutableData *a = [NSMutableData data], *b = [NSMutableData data];
        NSError *err = nil;
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:a];
        [[[TTIOAcquisitionSimulator alloc]
             initWithScanRate:5.0 duration:1.0 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:1]
            streamToWriter:tw error:&err];
        [tw close];
        tw = [[TTIOTransportWriter alloc] initWithMutableData:b];
        [[[TTIOAcquisitionSimulator alloc]
             initWithScanRate:5.0 duration:1.0 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:2]
            streamToWriter:tw error:&err];
        [tw close];
        PASS(![a isEqualToData:b], "different seeds → different streams");
    }

    // ── 4. Monotonic retention times ───────────────────────────────
    {
        NSMutableData *buf = [NSMutableData data];
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
        NSError *err = nil;
        [[[TTIOAcquisitionSimulator alloc]
             initWithScanRate:20.0 duration:1.5 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:7]
            streamToWriter:tw error:&err];
        [tw close];

        TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:buf];
        NSArray *packets = [tr readAllPacketsWithError:&err];
        double lastRt = -1.0;
        BOOL monotonic = YES;
        for (TTIOTransportPacketRecord *r in packets) {
            if (r.header.packetType != TTIOTransportPacketAccessUnit) continue;
            TTIOAccessUnit *au =
                [TTIOAccessUnit decodeFromBytes:(const uint8_t *)r.payload.bytes
                                          length:r.payload.length
                                           error:NULL];
            if (au.retentionTime < lastRt) { monotonic = NO; break; }
            lastRt = au.retentionTime;
        }
        PASS(monotonic, "retention times non-decreasing");
    }

    // ── 5. Materializes as a valid .tio ──────────────────────────
    {
        NSString *mots = tmp(@"sim.tis");
        NSString *ttio = tmp(@"sim.tio");
        rm(mots); rm(ttio);

        NSError *err = nil;
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithOutputPath:mots];
        NSUInteger n = [[[TTIOAcquisitionSimulator alloc] initWithSeed:42]
                            streamToWriter:tw error:&err];
        [tw close];
        PASS(n > 0, "default-seed simulator emits AUs");

        TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithInputPath:mots];
        BOOL ok = [tr writeTtioToPath:ttio error:&err];
        PASS(ok, ".tis → .tio materialises");
        if (ok) {
            TTIOSpectralDataset *rt =
                [TTIOSpectralDataset readFromFilePath:ttio error:&err];
            PASS(rt != nil, "materialised .tio opens");
            PASS([rt.title isEqualToString:@"Simulated acquisition"],
                 "title preserved from simulator");
            TTIOAcquisitionRun *run = rt.msRuns[@"simulated_run"];
            PASS(run && [run count] == n, "spectrum count matches emitted AU count");
        }
        rm(mots); rm(ttio);
    }
}
