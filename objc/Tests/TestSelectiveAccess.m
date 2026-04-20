/*
 * TestSelectiveAccess — v0.10 M71.
 *
 * Selective-access proportionality tests against a 600-scan
 * fixture, plus ProtectionMetadata wire round-trip and encrypted
 * flag propagation.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#include <string.h>

#import "Transport/MPGOTransportServer.h"
#import "Transport/MPGOTransportClient.h"
#import "Transport/MPGOTransportPacket.h"
#import "Transport/MPGOAccessUnit.h"
#import "Transport/MPGOProtectionMetadata.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOWrittenRun.h"
#import "ValueClasses/MPGOEnums.h"

static NSString *tmp(NSString *n) {
    return [NSString stringWithFormat:@"/tmp/mpgo_m71_%d_%@", (int)getpid(), n];
}
static void rm(NSString *p) { [[NSFileManager defaultManager] removeItemAtPath:p error:NULL]; }

static NSData *f64le(const double *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *i32arr(const int32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *u32arr(const uint32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *u64arr(const uint64_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}

static BOOL buildLargeFixture(NSString *path, NSError **error)
{
    NSUInteger n = 600;
    NSUInteger points = 4;
    NSUInteger total = n * points;
    double *mz = calloc(total, sizeof(double));
    double *intensity = calloc(total, sizeof(double));
    for (NSUInteger i = 0; i < total; i++) {
        mz[i] = 100.0 + (double)i;
        intensity[i] = 1.0 + (double)i;
    }
    uint64_t *offsets = calloc(n, sizeof(uint64_t));
    uint32_t *lengths = calloc(n, sizeof(uint32_t));
    double *rts = calloc(n, sizeof(double));
    int32_t *msLevels = calloc(n, sizeof(int32_t));
    int32_t *pols = calloc(n, sizeof(int32_t));
    double *pmzs = calloc(n, sizeof(double));
    int32_t *pcs = calloc(n, sizeof(int32_t));
    double *bpis = calloc(n, sizeof(double));
    for (NSUInteger i = 0; i < n; i++) {
        offsets[i] = i * points;
        lengths[i] = (uint32_t)points;
        rts[i] = 60.0 * (double)i / (double)(n - 1);
        msLevels[i] = (i % 2 == 0) ? 1 : 2;
        pols[i] = 1;
        pmzs[i] = msLevels[i] == 1 ? 0.0 : 500.0 + 0.1 * (double)i;
        pcs[i] = msLevels[i] == 1 ? 0 : 2;
        double best = 0.0;
        for (NSUInteger k = 0; k < points; k++) {
            double v = intensity[i * points + k];
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
    free(mz); free(intensity);
    free(offsets); free(lengths); free(rts);
    free(msLevels); free(pols); free(pmzs); free(pcs); free(bpis);
    return [MPGOSpectralDataset writeMinimalToPath:path
                                              title:@"M71 selective-access fixture"
                                 isaInvestigationId:@"ISA-M71-OBJC"
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

static NSArray *serveAndFetch(NSString *mpgo, NSDictionary *filters)
{
    MPGOTransportServer *srv =
        [[MPGOTransportServer alloc] initWithDatasetPath:mpgo host:@"127.0.0.1" port:0];
    NSError *err = nil;
    if (![srv startAndReturnError:&err]) return nil;
    NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%u/",
                      (unsigned)srv.actualPort];
    MPGOTransportClient *client = [[MPGOTransportClient alloc] initWithURL:url];
    NSArray *packets = [client fetchPacketsWithFilters:filters timeout:15.0 error:&err];
    [srv stopWithTimeout:2.0];
    return packets;
}

void testSelectiveAccess(void)
{
    NSString *mpgo = tmp(@"large.mpgo");
    rm(mpgo);
    NSError *err = nil;
    PASS(buildLargeFixture(mpgo, &err), "M71: large fixture built");

    // ── 1. RT range filter reduces transfer ───────────────────────
    {
        NSArray *filtered = serveAndFetch(mpgo, @{@"rt_min": @(10.0),
                                                   @"rt_max": @(12.0)});
        NSArray *full = serveAndFetch(mpgo, nil);
        NSUInteger fc = countAUs(filtered), tc = countAUs(full);
        PASS(tc > 0, "full stream returns AUs");
        PASS(fc > 0, "RT filter returns at least one AU");
        PASS((double)fc / (double)tc < 0.05,
             "RT range 10-12s out of 0-60s: <5% of AUs");
    }

    // ── 2. ms_level=2 halves the stream ───────────────────────────
    {
        NSArray *p = serveAndFetch(mpgo, @{@"ms_level": @(2)});
        PASS(countAUs(p) == 300, "ms_level=2 yields exactly 300 AUs");
    }

    // ── 3. max_au cap ─────────────────────────────────────────────
    {
        NSArray *p = serveAndFetch(mpgo, @{@"max_au": @(100)});
        PASS(countAUs(p) == 100, "max_au=100 yields exactly 100 AUs");
        MPGOTransportPacketRecord *last = p.lastObject;
        PASS(last.header.packetType == MPGOTransportPacketEndOfStream,
             "capped stream still terminates with EndOfStream");
    }

    // ── 4. Combined filter: RT + ms_level ────────────────────────
    {
        NSArray *rtOnly = serveAndFetch(mpgo,
            @{@"rt_min": @(10.0), @"rt_max": @(30.0)});
        NSArray *combined = serveAndFetch(mpgo,
            @{@"rt_min": @(10.0), @"rt_max": @(30.0), @"ms_level": @(2)});
        NSUInteger r = countAUs(rtOnly), c = countAUs(combined);
        PASS(c < r, "combined filter strictly narrows rt-only");
        double ratio = (double)c / (double)r;
        PASS(ratio >= 0.4 && ratio <= 0.6,
             "combined/rt_only ratio in [0.4, 0.6]");
    }

    // ── 5. No-match → skeleton only ──────────────────────────────
    {
        NSArray *p = serveAndFetch(mpgo, @{@"ms_level": @(99)});
        PASS(countAUs(p) == 0, "impossible filter yields 0 AUs");
        MPGOTransportPacketRecord *first = p.firstObject;
        MPGOTransportPacketRecord *last = p.lastObject;
        PASS(first.header.packetType == MPGOTransportPacketStreamHeader,
             "skeleton: StreamHeader first");
        PASS(last.header.packetType == MPGOTransportPacketEndOfStream,
             "skeleton: EndOfStream last");
    }

    rm(mpgo);

    // ── 6. ProtectionMetadata wire round-trip (AES-GCM) ──────────
    {
        uint8_t wrappedBytes[256]; memset(wrappedBytes, 1, sizeof(wrappedBytes));
        uint8_t pkBytes[32]; memset(pkBytes, 2, sizeof(pkBytes));
        MPGOProtectionMetadata *pm =
            [[MPGOProtectionMetadata alloc]
                initWithCipherSuite:@"aes-256-gcm"
                       kekAlgorithm:@"rsa-oaep-sha256"
                        wrappedDek:[NSData dataWithBytes:wrappedBytes length:256]
                 signatureAlgorithm:@"ed25519"
                          publicKey:[NSData dataWithBytes:pkBytes length:32]];
        NSData *raw = [pm encode];
        MPGOProtectionMetadata *d = [MPGOProtectionMetadata decodeFromData:raw];
        PASS([d.cipherSuite isEqualToString:@"aes-256-gcm"],
             "ProtectionMetadata: cipher_suite round-trips");
        PASS([d.kekAlgorithm isEqualToString:@"rsa-oaep-sha256"],
             "ProtectionMetadata: kek_algorithm round-trips");
        PASS(d.wrappedDek.length == 256
             && [d.wrappedDek isEqualToData:pm.wrappedDek],
             "ProtectionMetadata: wrapped_dek round-trips");
        PASS([d.signatureAlgorithm isEqualToString:@"ed25519"],
             "ProtectionMetadata: signature_algorithm round-trips");
        PASS(d.publicKey.length == 32
             && [d.publicKey isEqualToData:pm.publicKey],
             "ProtectionMetadata: public_key round-trips");
    }

    // ── 7. ProtectionMetadata PQC (large blobs) ──────────────────
    {
        NSMutableData *wrapped = [NSMutableData dataWithLength:1568];
        NSMutableData *pk = [NSMutableData dataWithLength:2592];
        memset(wrapped.mutableBytes, 0xFF, 1568);
        memset(pk.mutableBytes, 0xAA, 2592);
        MPGOProtectionMetadata *pm =
            [[MPGOProtectionMetadata alloc]
                initWithCipherSuite:@"aes-256-gcm"
                       kekAlgorithm:@"ml-kem-1024"
                        wrappedDek:wrapped
                 signatureAlgorithm:@"ml-dsa-87"
                          publicKey:pk];
        MPGOProtectionMetadata *d =
            [MPGOProtectionMetadata decodeFromData:[pm encode]];
        PASS([d.kekAlgorithm isEqualToString:@"ml-kem-1024"]
             && [d.signatureAlgorithm isEqualToString:@"ml-dsa-87"],
             "ProtectionMetadata PQC: algorithm strings round-trip");
        PASS(d.wrappedDek.length == 1568 && d.publicKey.length == 2592,
             "ProtectionMetadata PQC: large blob lengths preserved");
    }

    // ── 8. Encrypted flag on AU header ───────────────────────────
    {
        MPGOTransportPacketHeader *h =
            [[MPGOTransportPacketHeader alloc]
                initWithPacketType:MPGOTransportPacketAccessUnit
                              flags:(uint16_t)MPGOTransportPacketFlagEncrypted
                          datasetId:1
                         auSequence:0
                      payloadLength:38
                        timestampNs:0];
        NSData *raw = [h encode];
        MPGOTransportPacketHeader *d =
            [MPGOTransportPacketHeader decodeFromBytes:(const uint8_t *)raw.bytes
                                                  length:raw.length
                                                   error:NULL];
        PASS(d.flags & MPGOTransportPacketFlagEncrypted,
             "encrypted flag round-trips on AU header");
    }
}
