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

#import "Transport/MPGOAcquisitionSimulator.h"
#import "Transport/MPGOTransportWriter.h"
#import "Transport/MPGOTransportReader.h"
#import "Transport/MPGOTransportPacket.h"
#import "Transport/MPGOAccessUnit.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Run/MPGOAcquisitionRun.h"

static NSString *tmp(NSString *name)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_m69_%d_%@",
            (int)getpid(), name];
}

static void rm(NSString *p) { [[NSFileManager defaultManager] removeItemAtPath:p error:NULL]; }

static NSUInteger countAUs(NSArray<MPGOTransportPacketRecord *> *packets)
{
    NSUInteger n = 0;
    for (MPGOTransportPacketRecord *r in packets) {
        if (r.header.packetType == MPGOTransportPacketAccessUnit) n++;
    }
    return n;
}

void testAcquisitionSimulator(void)
{
    // ── 1. Scan count ─────────────────────────────────────────────
    {
        NSMutableData *buf = [NSMutableData data];
        MPGOTransportWriter *tw = [[MPGOTransportWriter alloc] initWithMutableData:buf];
        MPGOAcquisitionSimulator *sim =
            [[MPGOAcquisitionSimulator alloc]
                initWithScanRate:10.0 duration:2.0 ms1Fraction:0.3
                           mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:1];
        NSError *err = nil;
        NSUInteger n = [sim streamToWriter:tw error:&err];
        [tw close];
        PASS(n == 20, "simulator emits scan_rate * duration AUs");

        MPGOTransportReader *tr = [[MPGOTransportReader alloc] initWithData:buf];
        NSArray<MPGOTransportPacketRecord *> *packets =
            [tr readAllPacketsWithError:&err];
        PASS(packets != nil, "simulator output parses cleanly");
        PASS(countAUs(packets) == 20, "20 AU packets in stream");
    }

    // ── 2. Deterministic under same seed ───────────────────────────
    {
        NSMutableData *a = [NSMutableData data], *b = [NSMutableData data];
        NSError *err = nil;
        MPGOTransportWriter *tw = [[MPGOTransportWriter alloc] initWithMutableData:a];
        [[[MPGOAcquisitionSimulator alloc]
             initWithScanRate:5.0 duration:1.0 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:42]
            streamToWriter:tw error:&err];
        [tw close];

        tw = [[MPGOTransportWriter alloc] initWithMutableData:b];
        [[[MPGOAcquisitionSimulator alloc]
             initWithScanRate:5.0 duration:1.0 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:42]
            streamToWriter:tw error:&err];
        [tw close];

        // Parse both into packet records; compare payloads
        // (timestamps differ per packet).
        MPGOTransportReader *trA = [[MPGOTransportReader alloc] initWithData:a];
        MPGOTransportReader *trB = [[MPGOTransportReader alloc] initWithData:b];
        NSArray *pa = [trA readAllPacketsWithError:&err];
        NSArray *pb = [trB readAllPacketsWithError:&err];
        BOOL equal = (pa.count == pb.count);
        if (equal) {
            for (NSUInteger i = 0; i < pa.count && equal; i++) {
                MPGOTransportPacketRecord *ra = pa[i];
                MPGOTransportPacketRecord *rb = pb[i];
                if (![ra.payload isEqualToData:rb.payload]) { equal = NO; break; }
            }
        }
        PASS(equal, "same seed → identical AU payloads");
    }

    // ── 3. Different seeds differ ──────────────────────────────────
    {
        NSMutableData *a = [NSMutableData data], *b = [NSMutableData data];
        NSError *err = nil;
        MPGOTransportWriter *tw = [[MPGOTransportWriter alloc] initWithMutableData:a];
        [[[MPGOAcquisitionSimulator alloc]
             initWithScanRate:5.0 duration:1.0 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:1]
            streamToWriter:tw error:&err];
        [tw close];
        tw = [[MPGOTransportWriter alloc] initWithMutableData:b];
        [[[MPGOAcquisitionSimulator alloc]
             initWithScanRate:5.0 duration:1.0 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:2]
            streamToWriter:tw error:&err];
        [tw close];
        PASS(![a isEqualToData:b], "different seeds → different streams");
    }

    // ── 4. Monotonic retention times ───────────────────────────────
    {
        NSMutableData *buf = [NSMutableData data];
        MPGOTransportWriter *tw = [[MPGOTransportWriter alloc] initWithMutableData:buf];
        NSError *err = nil;
        [[[MPGOAcquisitionSimulator alloc]
             initWithScanRate:20.0 duration:1.5 ms1Fraction:0.3
                        mzMin:100.0 mzMax:2000.0 nPeaks:50 seed:7]
            streamToWriter:tw error:&err];
        [tw close];

        MPGOTransportReader *tr = [[MPGOTransportReader alloc] initWithData:buf];
        NSArray *packets = [tr readAllPacketsWithError:&err];
        double lastRt = -1.0;
        BOOL monotonic = YES;
        for (MPGOTransportPacketRecord *r in packets) {
            if (r.header.packetType != MPGOTransportPacketAccessUnit) continue;
            MPGOAccessUnit *au =
                [MPGOAccessUnit decodeFromBytes:(const uint8_t *)r.payload.bytes
                                          length:r.payload.length
                                           error:NULL];
            if (au.retentionTime < lastRt) { monotonic = NO; break; }
            lastRt = au.retentionTime;
        }
        PASS(monotonic, "retention times non-decreasing");
    }

    // ── 5. Materializes as a valid .mpgo ──────────────────────────
    {
        NSString *mots = tmp(@"sim.mots");
        NSString *mpgo = tmp(@"sim.mpgo");
        rm(mots); rm(mpgo);

        NSError *err = nil;
        MPGOTransportWriter *tw = [[MPGOTransportWriter alloc] initWithOutputPath:mots];
        NSUInteger n = [[[MPGOAcquisitionSimulator alloc] initWithSeed:42]
                            streamToWriter:tw error:&err];
        [tw close];
        PASS(n > 0, "default-seed simulator emits AUs");

        MPGOTransportReader *tr = [[MPGOTransportReader alloc] initWithInputPath:mots];
        BOOL ok = [tr writeMpgoToPath:mpgo error:&err];
        PASS(ok, ".mots → .mpgo materialises");
        if (ok) {
            MPGOSpectralDataset *rt =
                [MPGOSpectralDataset readFromFilePath:mpgo error:&err];
            PASS(rt != nil, "materialised .mpgo opens");
            PASS([rt.title isEqualToString:@"Simulated acquisition"],
                 "title preserved from simulator");
            MPGOAcquisitionRun *run = rt.msRuns[@"simulated_run"];
            PASS(run && [run count] == n, "spectrum count matches emitted AU count");
        }
        rm(mots); rm(mpgo);
    }
}
