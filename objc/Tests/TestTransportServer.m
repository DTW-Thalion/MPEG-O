/*
 * TestTransportServer — v0.10 M68.5 parity backfill.
 *
 * Verifies MPGOTransportServer + MPGOTransportClient talking
 * to each other (ObjC ↔ ObjC; no Python subprocess needed).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Transport/MPGOTransportServer.h"
#import "Transport/MPGOTransportClient.h"
#import "Transport/MPGOTransportPacket.h"
#import "Transport/MPGOAccessUnit.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOWrittenRun.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "ValueClasses/MPGOEnums.h"

static NSString *tmp(NSString *n) {
    return [NSString stringWithFormat:@"/tmp/mpgo_m685_%d_%@",
            (int)getpid(), n];
}
static void rm(NSString *p) { [[NSFileManager defaultManager] removeItemAtPath:p error:NULL]; }

static NSData *f64le(const double *v, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *i32arr(const int32_t *v, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *u32arr(const uint32_t *v, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *u64arr(const uint64_t *v, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}

static BOOL buildFixture(NSString *path, NSError **error)
{
    NSUInteger n = 5, p = 3, total = n * p;
    double mz[15], intensity[15];
    for (NSUInteger i = 0; i < total; i++) {
        mz[i] = 100.0 + i;
        intensity[i] = 100.0 * (i + 1);
    }
    uint64_t offsets[5] = {0, 3, 6, 9, 12};
    uint32_t lengths[5] = {3, 3, 3, 3, 3};
    double rts[5] = {1.0, 2.0, 3.0, 4.0, 5.0};
    int32_t msLevels[5] = {1, 2, 1, 2, 1};
    int32_t pols[5] = {1, 1, 1, 1, 1};
    double pmzs[5] = {0.0, 510.0, 0.0, 530.0, 0.0};
    int32_t pcs[5] = {0, 2, 0, 2, 0};
    double bpis[5];
    for (NSUInteger i = 0; i < n; i++) {
        double best = 0.0;
        for (NSUInteger k = 0; k < p; k++) {
            double v = intensity[i * p + k];
            if (v > best) best = v;
        }
        bpis[i] = best;
    }
    MPGOWrittenRun *run =
        [[MPGOWrittenRun alloc]
            initWithSpectrumClassName:@"MPGOMassSpectrum"
                      acquisitionMode:(int64_t)MPGOAcquisitionModeMS1DDA
                          channelData:@{@"mz": f64le(mz, total),
                                        @"intensity": f64le(intensity, total)}
                              offsets:u64arr(offsets, n)
                              lengths:u32arr(lengths, n)
                       retentionTimes:f64le(rts, n)
                             msLevels:i32arr(msLevels, n)
                           polarities:i32arr(pols, n)
                         precursorMzs:f64le(pmzs, n)
                     precursorCharges:i32arr(pcs, n)
                  basePeakIntensities:f64le(bpis, n)];
    return [MPGOSpectralDataset writeMinimalToPath:path
                                              title:@"M68.5 server fixture"
                                 isaInvestigationId:@"ISA-M685"
                                             msRuns:@{@"run_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

static NSUInteger countAUs(NSArray<MPGOTransportPacketRecord *> *packets)
{
    NSUInteger n = 0;
    for (MPGOTransportPacketRecord *r in packets) {
        if (r.header.packetType == MPGOTransportPacketAccessUnit) n++;
    }
    return n;
}

void testTransportServer(void)
{
    NSString *mpgo = tmp(@"src.mpgo");
    rm(mpgo);
    NSError *err = nil;
    BOOL ok = buildFixture(mpgo, &err);
    PASS(ok, "M68.5: fixture build succeeds");
    if (!ok) return;

    // ── 1. Unfiltered stream ──────────────────────────────────────
    {
        MPGOTransportServer *srv =
            [[MPGOTransportServer alloc] initWithDatasetPath:mpgo
                                                         host:@"127.0.0.1"
                                                         port:0];
        NSError *startErr = nil;
        BOOL started = [srv startAndReturnError:&startErr];
        PASS(started, "ObjC server starts");
        PASS(srv.actualPort > 0, "server binds to a port");

        NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%u/",
                          (unsigned)srv.actualPort];
        MPGOTransportClient *client = [[MPGOTransportClient alloc] initWithURL:url];
        NSError *fetchErr = nil;
        NSArray *packets = [client fetchPacketsWithFilters:nil timeout:10.0 error:&fetchErr];
        PASS(packets != nil, "ObjC server replies with packets");
        PASS(countAUs(packets) == 5, "unfiltered stream: 5 AUs");

        [srv stopWithTimeout:2.0];
    }

    // ── 2. ms_level filter ────────────────────────────────────────
    {
        MPGOTransportServer *srv =
            [[MPGOTransportServer alloc] initWithDatasetPath:mpgo
                                                         host:@"127.0.0.1"
                                                         port:0];
        NSError *startErr = nil;
        [srv startAndReturnError:&startErr];

        NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%u/",
                          (unsigned)srv.actualPort];
        MPGOTransportClient *client = [[MPGOTransportClient alloc] initWithURL:url];
        NSError *fetchErr = nil;
        NSArray *packets = [client fetchPacketsWithFilters:@{@"ms_level": @(2)}
                                                    timeout:10.0 error:&fetchErr];
        PASS(countAUs(packets) == 2, "ms_level=2 filter: 2 AUs");

        [srv stopWithTimeout:2.0];
    }

    // ── 3. RT range filter ────────────────────────────────────────
    {
        MPGOTransportServer *srv =
            [[MPGOTransportServer alloc] initWithDatasetPath:mpgo
                                                         host:@"127.0.0.1"
                                                         port:0];
        NSError *startErr = nil;
        [srv startAndReturnError:&startErr];

        NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%u/",
                          (unsigned)srv.actualPort];
        MPGOTransportClient *client = [[MPGOTransportClient alloc] initWithURL:url];
        NSError *fetchErr = nil;
        NSArray *packets = [client fetchPacketsWithFilters:@{@"rt_min": @(2.5),
                                                                @"rt_max": @(4.0)}
                                                    timeout:10.0 error:&fetchErr];
        PASS(countAUs(packets) == 2, "rt range 2.5..4.0: 2 AUs");

        [srv stopWithTimeout:2.0];
    }

    // ── 4. max_au cap ─────────────────────────────────────────────
    {
        MPGOTransportServer *srv =
            [[MPGOTransportServer alloc] initWithDatasetPath:mpgo
                                                         host:@"127.0.0.1"
                                                         port:0];
        NSError *startErr = nil;
        [srv startAndReturnError:&startErr];

        NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%u/",
                          (unsigned)srv.actualPort];
        MPGOTransportClient *client = [[MPGOTransportClient alloc] initWithURL:url];
        NSError *fetchErr = nil;
        NSArray *packets = [client fetchPacketsWithFilters:@{@"max_au": @(2)}
                                                    timeout:10.0 error:&fetchErr];
        PASS(countAUs(packets) == 2, "max_au=2 cap: 2 AUs");

        [srv stopWithTimeout:2.0];
    }

    // ── 5. materialize end-to-end ─────────────────────────────────
    {
        MPGOTransportServer *srv =
            [[MPGOTransportServer alloc] initWithDatasetPath:mpgo
                                                         host:@"127.0.0.1"
                                                         port:0];
        NSError *startErr = nil;
        [srv startAndReturnError:&startErr];

        NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%u/",
                          (unsigned)srv.actualPort];
        MPGOTransportClient *client = [[MPGOTransportClient alloc] initWithURL:url];
        NSString *out = tmp(@"server-rt.mpgo");
        rm(out);
        NSError *wErr = nil;
        BOOL matOk = [client streamToFilePath:out filters:nil error:&wErr];
        PASS(matOk, "stream-to-file materialisation succeeds");
        if (matOk) {
            MPGOSpectralDataset *rt =
                [MPGOSpectralDataset readFromFilePath:out error:&wErr];
            PASS([rt.title isEqualToString:@"M68.5 server fixture"],
                 "title preserved");
            PASS([rt.msRuns[@"run_0001"] count] == 5, "5 spectra materialised");
        }
        rm(out);

        [srv stopWithTimeout:2.0];
    }

    rm(mpgo);
}
