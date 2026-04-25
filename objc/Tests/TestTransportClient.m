/*
 * TestTransportClient — v0.10 M68.
 *
 * Spawns the Python reference server via
 * ``python -m ttio.tools.transport_server_cli`` and exercises
 * TTIOTransportClient against it.
 *
 * Skipped when python3 or the ttio package is unavailable on PATH.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Transport/TTIOTransportClient.h"
#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOTransportReader.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *tmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m68_%d_%@",
            (int)getpid(), suffix];
}

static void rmFile(NSString *p) { [[NSFileManager defaultManager] removeItemAtPath:p error:NULL]; }

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
    TTIOWrittenRun *run =
        [[TTIOWrittenRun alloc]
            initWithSpectrumClassName:@"TTIOMassSpectrum"
                      acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
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
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"M68 ObjC client fixture"
                                 isaInvestigationId:@"ISA-M68-OBJC"
                                             msRuns:@{@"run_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

/**
 * Spawn the Python server CLI. Reads lines from its stdout until
 * ``PORT=<n>`` appears, then returns the port. Leaves the process
 * handle in ``*outTask`` so the caller can terminate it.
 */
static int spawnPythonServer(NSString *ttioPath, NSTask **outTask)
{
    NSString *venvPy = [NSString stringWithFormat:@"%@/TTI-O/python/.venv/bin/python",
                         NSHomeDirectory()];
    NSString *launcher = [[NSFileManager defaultManager] isExecutableFileAtPath:venvPy]
                        ? venvPy : @"/usr/bin/python3";

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launcher;
    task.arguments = @[@"-m", @"ttio.tools.transport_server_cli",
                       ttioPath, @"--port", @"0"];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return -1;
    }

    NSFileHandle *rh = out.fileHandleForReading;
    NSMutableData *buf = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSData *chunk = [rh availableData];
        if (chunk.length == 0) {
            [NSThread sleepForTimeInterval:0.05];
            continue;
        }
        [buf appendData:chunk];
        NSString *text = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        NSRange r = [text rangeOfString:@"PORT="];
        if (r.location != NSNotFound) {
            NSString *tail = [text substringFromIndex:r.location + r.length];
            NSRange nl = [tail rangeOfString:@"\n"];
            NSString *portStr = nl.location == NSNotFound
                ? tail : [tail substringToIndex:nl.location];
            if (outTask) *outTask = task;
            return [portStr intValue];
        }
    }
    [task terminate];
    return -1;
}

void testTransportClient(void)
{
    NSString *fixturePath = tmpPath(@"srv-src.tio");
    rmFile(fixturePath);

    NSError *err = nil;
    BOOL ok = buildFixture(fixturePath, &err);
    PASS(ok, "M68: fixture build succeeds");
    if (!ok) return;

    NSTask *task = nil;
    int port = spawnPythonServer(fixturePath, &task);
    if (port <= 0) {
        PASS(0, "Python server unreachable (ttio venv missing? skipping remainder)");
        rmFile(fixturePath);
        return;
    }
    PASS(port > 0, "Python transport server spawned");

    NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%d/", port];

    // ── 1. Unfiltered stream ──────────────────────────────────────
    {
        TTIOTransportClient *client = [[TTIOTransportClient alloc] initWithURL:url];
        NSError *fetchErr = nil;
        NSArray<TTIOTransportPacketRecord *> *packets =
            [client fetchPacketsWithFilters:nil timeout:10.0 error:&fetchErr];
        PASS(packets != nil && packets.count > 0,
             "ObjC client receives packets from Python server");
        NSUInteger auCount = 0;
        for (TTIOTransportPacketRecord *rec in packets) {
            if (rec.header.packetType == TTIOTransportPacketAccessUnit) auCount++;
        }
        PASS(auCount == 5, "unfiltered stream delivers all 5 AUs");
        PASS(((TTIOTransportPacketRecord *)packets.lastObject).header.packetType
             == TTIOTransportPacketEndOfStream,
             "last packet is EndOfStream");
    }

    // ── 2. ms_level filter ────────────────────────────────────────
    {
        TTIOTransportClient *client = [[TTIOTransportClient alloc] initWithURL:url];
        NSError *fetchErr = nil;
        NSArray<TTIOTransportPacketRecord *> *packets =
            [client fetchPacketsWithFilters:@{@"ms_level": @(2)}
                                     timeout:10.0 error:&fetchErr];
        PASS(packets != nil, "ms_level filter: client returns packets");
        NSUInteger auCount = 0;
        for (TTIOTransportPacketRecord *rec in packets) {
            if (rec.header.packetType == TTIOTransportPacketAccessUnit) auCount++;
        }
        PASS(auCount == 2, "ms_level=2 filter delivers 2 AUs");
    }

    // ── 3. RT range filter ────────────────────────────────────────
    {
        TTIOTransportClient *client = [[TTIOTransportClient alloc] initWithURL:url];
        NSError *fetchErr = nil;
        NSArray<TTIOTransportPacketRecord *> *packets =
            [client fetchPacketsWithFilters:@{@"rt_min": @(2.5), @"rt_max": @(4.0)}
                                     timeout:10.0 error:&fetchErr];
        NSUInteger auCount = 0;
        for (TTIOTransportPacketRecord *rec in packets) {
            if (rec.header.packetType == TTIOTransportPacketAccessUnit) auCount++;
        }
        PASS(auCount == 2, "rt range 2.5..4.0 filter delivers 2 AUs");
    }

    // ── 4. Materialize stream to .tio ────────────────────────────
    {
        TTIOTransportClient *client = [[TTIOTransportClient alloc] initWithURL:url];
        NSString *out = tmpPath(@"client-rt.tio");
        rmFile(out);
        NSError *wErr = nil;
        BOOL matOk = [client streamToFilePath:out filters:nil error:&wErr];
        PASS(matOk, "streamToFilePath succeeds");
        if (matOk) {
            TTIOSpectralDataset *rt =
                [TTIOSpectralDataset readFromFilePath:out error:&wErr];
            PASS(rt != nil, "streamed .tio reopens");
            PASS([rt.title isEqualToString:@"M68 ObjC client fixture"],
                 "title preserved through network streaming");
            TTIOAcquisitionRun *run = rt.msRuns[@"run_0001"];
            PASS([run count] == 5, "5 spectra after streaming");
        }
        rmFile(out);
    }

    [task terminate];
    [task waitUntilExit];
    rmFile(fixturePath);
}
