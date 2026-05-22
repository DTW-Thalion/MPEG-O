/*
 * TestC2aServerKekId — FD-1 Phase C-2a (ObjC).
 *
 * server_kek_id carriage: a stamped <channel>_server_kek_id survives
 * stamp -> write packet -> read -> re-stamp. Mirrors the Python
 * test_fd1_c2a_server_kek_id.py / Java ServerKekIdProtectionTest. BYOK
 * (no server_kek_id) stays clean.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#import <string.h>

#import "Transport/TTIOEncryptedTransport.h"
#import "Transport/TTIOTransportWriter.h"
#import "Protection/TTIOPerAUFile.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "HDF5/TTIOHDF5File.h"
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *kidPath(NSString *n) {
    return [NSString stringWithFormat:@"/tmp/ttio_c2a_%d_%@", (int)getpid(), n];
}
static void kidRm(NSString *p) {
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}
static NSData *kidKey(void) { uint8_t b[32]; memset(b, 0x5A, 32);
    return [NSData dataWithBytes:b length:32]; }
static NSData *kidFilled(NSUInteger n, uint8_t v) { uint8_t *b = malloc(n);
    memset(b, v, n); NSData *d = [NSData dataWithBytes:b length:n]; free(b); return d; }

static NSData *f64(const double *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *u64(const uint64_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *u32(const uint32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *i32(const int32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}

static BOOL c2aBuildFixture(NSString *path, NSError **error) {
    NSUInteger n = 3, total = 12;
    double mz[12], intensity[12];
    for (NSUInteger i = 0; i < total; i++) { mz[i] = 100.0 + i; intensity[i] = (i + 1) * 10.0; }
    uint64_t offsets[3] = {0, 4, 8}; uint32_t lengths[3] = {4, 4, 4};
    double rts[3] = {1, 2, 3}; int32_t msl[3] = {1, 2, 1}; int32_t pol[3] = {1, 1, 1};
    double pmz[3] = {0, 500, 0}; int32_t pc[3] = {0, 2, 0}; double bpi[3] = {40, 80, 120};
    TTIOWrittenRun *run = [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:@{@"mz": f64(mz, total), @"intensity": f64(intensity, total)}
                          offsets:u64(offsets, n) lengths:u32(lengths, n)
                   retentionTimes:f64(rts, n) msLevels:i32(msl, n) polarities:i32(pol, n)
                     precursorMzs:f64(pmz, n) precursorCharges:i32(pc, n)
              basePeakIntensities:f64(bpi, n)];
    if (![TTIOSpectralDataset writeMinimalToPath:path title:@"c2a" isaInvestigationId:@"ISA-C2A"
                                          msRuns:@{@"run_0001": run}
                                 identifications:nil quantifications:nil
                               provenanceRecords:nil error:error]) return NO;
    return [TTIOPerAUFile encryptFilePath:path key:kidKey() encryptHeaders:NO
                            providerName:nil error:error];
}

static id<TTIOStorageGroup> c2aSignalChannels(TTIOHDF5File *f) {
    return [[[[[f rootGroup] openGroupNamed:@"study" error:NULL]
        openGroupNamed:@"ms_runs" error:NULL]
        openGroupNamed:@"run_0001" error:NULL]
        openGroupNamed:@"signal_channels" error:NULL];
}
static NSString *c2aFirstChannel(id<TTIOStorageGroup> sig) {
    NSString *names = [sig attributeValueForName:@"channel_names" error:NULL];
    return [names componentsSeparatedByString:@","].firstObject ?: @"intensity";
}

static NSString *c2aRoundTripServerKekId(NSString *kid) {
    NSData *SERVER = kidFilled(48, 0x11);
    NSString *src = kidPath(@"src.tio"); kidRm(src);
    NSError *err = nil;
    if (!c2aBuildFixture(src, &err)) return @"<fixture-failed>";

    TTIOHDF5File *fw = [TTIOHDF5File openAtPath:src error:&err];
    id<TTIOStorageGroup> sig = c2aSignalChannels(fw);
    NSString *fc = c2aFirstChannel(sig);
    [sig setAttributeValue:SERVER forName:[NSString stringWithFormat:@"%@_wrapped_dek", fc] error:NULL];
    [sig setAttributeValue:@"aes-256-gcm" forName:[NSString stringWithFormat:@"%@_kek_algorithm", fc] error:NULL];
    if (kid) {
        [sig setAttributeValue:kid forName:[NSString stringWithFormat:@"%@_server_kek_id", fc] error:NULL];
    }
    [fw close];

    NSMutableData *streamBuf = [NSMutableData data];
    TTIOTransportWriter *writer = [[TTIOTransportWriter alloc] initWithMutableData:streamBuf];
    [TTIOEncryptedTransport writeEncryptedDataset:src writer:writer providerName:nil error:&err];
    [writer close];

    NSString *dst = kidPath(@"dst.tio"); kidRm(dst);
    [TTIOEncryptedTransport readEncryptedToPath:dst fromStream:streamBuf providerName:nil error:&err];

    TTIOHDF5File *fr = [TTIOHDF5File openReadOnlyAtPath:dst error:&err];
    id<TTIOStorageGroup> dsig = c2aSignalChannels(fr);
    NSString *dfc = c2aFirstChannel(dsig);
    NSString *attr = [NSString stringWithFormat:@"%@_server_kek_id", dfc];
    NSString *got = [dsig hasAttributeNamed:attr]
        ? [dsig attributeValueForName:attr error:NULL] : nil;
    [fr close];
    kidRm(src); kidRm(dst);
    return got;
}

void testC2aServerKekId(void)
{
    NSString *got = c2aRoundTripServerKekId(@"server:kek-proj-adni");
    PASS([got isEqualToString:@"server:kek-proj-adni"],
         "server_kek_id round-trips through write -> read");

    NSString *byok = c2aRoundTripServerKekId(nil);
    PASS(byok == nil, "BYOK container carries no server_kek_id");
}
