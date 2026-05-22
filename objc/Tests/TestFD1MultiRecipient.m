/*
 * TestFD1MultiRecipient — FD-1 Phase A-3 (ObjC).
 *
 * Multi-recipient ProtectionMetadata carriage: a per-run DEK wrapped for
 * several recipients survives stamp -> write packet -> read -> store.
 * Mirrors the Python `test_fd1_multi_recipient_protection.py` and the
 * Java `MultiRecipientProtectionTest`; single-recipient stays unchanged.
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

static NSString *fdPath(NSString *n) {
    return [NSString stringWithFormat:@"/tmp/ttio_fd1_%d_%@", (int)getpid(), n];
}
static void fdRm(NSString *p) {
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}
static NSData *fdKey(void) { uint8_t b[32]; memset(b, 0x5A, 32);
    return [NSData dataWithBytes:b length:32]; }
static NSData *fdFilled(NSUInteger n, uint8_t v) { uint8_t *b = malloc(n);
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

// Explicit little-endian appends so the expected block is host-independent.
static void appU16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = {(uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF)};
    [d appendBytes:b length:2];
}
static void appU32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF),
                    (uint8_t)((v >> 16) & 0xFF), (uint8_t)((v >> 24) & 0xFF)};
    [d appendBytes:b length:4];
}
static void appStr(NSMutableData *d, NSString *s) {
    NSData *u = [s dataUsingEncoding:NSUTF8StringEncoding];
    appU16(d, (uint16_t)u.length); [d appendData:u];
}

/** Build the expected recipient block: count=1, then the researcher entry. */
static NSData *expectedBlock(NSData *researcherWrap) {
    NSMutableData *b = [NSMutableData data];
    appU16(b, 1);
    appStr(b, @"researcher");
    appStr(b, @"ml-kem-1024");
    appU32(b, (uint32_t)researcherWrap.length);
    [b appendData:researcherWrap];
    return b;
}

static BOOL buildFixture(NSString *path, NSError **error) {
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
    if (![TTIOSpectralDataset writeMinimalToPath:path title:@"fd1" isaInvestigationId:@"ISA-FD1"
                                          msRuns:@{@"run_0001": run}
                                 identifications:nil quantifications:nil
                               provenanceRecords:nil error:error]) return NO;
    return [TTIOPerAUFile encryptFilePath:path key:fdKey() encryptHeaders:NO
                            providerName:nil error:error];
}

static id<TTIOStorageGroup> openSignalChannels(TTIOHDF5File *f) {
    id<TTIOStorageGroup> g = [[[[[f rootGroup] openGroupNamed:@"study" error:NULL]
        openGroupNamed:@"ms_runs" error:NULL]
        openGroupNamed:@"run_0001" error:NULL]
        openGroupNamed:@"signal_channels" error:NULL];
    return g;
}

static NSString *firstChannel(id<TTIOStorageGroup> sig) {
    NSString *names = [sig attributeValueForName:@"channel_names" error:NULL];
    NSArray *parts = [names componentsSeparatedByString:@","];
    return parts.firstObject ?: @"intensity";
}

void testFD1MultiRecipient(void)
{
    NSData *SERVER = fdFilled(48, 0x11);
    NSData *RESEARCHER = fdFilled(1639, 0x22);
    NSData *block = expectedBlock(RESEARCHER);

    // ── multi-recipient carriage ──────────────────────────────────
    {
        NSString *src = fdPath(@"multi_src.tio"); fdRm(src);
        NSError *err = nil;
        PASS(buildFixture(src, &err), "FD1 fixture built");

        TTIOHDF5File *fw = [TTIOHDF5File openAtPath:src error:&err];
        id<TTIOStorageGroup> sig = openSignalChannels(fw);
        NSString *fc = firstChannel(sig);
        [sig setAttributeValue:SERVER forName:[NSString stringWithFormat:@"%@_wrapped_dek", fc] error:NULL];
        [sig setAttributeValue:@"aes-256-gcm" forName:[NSString stringWithFormat:@"%@_kek_algorithm", fc] error:NULL];
        [sig setAttributeValue:block forName:[NSString stringWithFormat:@"%@_wrapped_dek_recipients", fc] error:NULL];
        [fw close];

        NSMutableData *streamBuf = [NSMutableData data];
        TTIOTransportWriter *writer = [[TTIOTransportWriter alloc] initWithMutableData:streamBuf];
        PASS([TTIOEncryptedTransport writeEncryptedDataset:src writer:writer providerName:nil error:&err],
             "writeEncryptedDataset (multi-recipient) succeeds");
        [writer close];

        NSString *dst = fdPath(@"multi_dst.tio"); fdRm(dst);
        PASS([TTIOEncryptedTransport readEncryptedToPath:dst fromStream:streamBuf providerName:nil error:&err],
             "readEncryptedToPath (multi-recipient) succeeds");

        TTIOHDF5File *fr = [TTIOHDF5File openReadOnlyAtPath:dst error:&err];
        id<TTIOStorageGroup> dsig = openSignalChannels(fr);
        NSString *dfc = firstChannel(dsig);
        NSData *gotPrimary = [dsig attributeValueForName:[NSString stringWithFormat:@"%@_wrapped_dek", dfc] error:NULL];
        NSData *gotBlock = [dsig attributeValueForName:[NSString stringWithFormat:@"%@_wrapped_dek_recipients", dfc] error:NULL];
        PASS([gotPrimary isEqualToData:SERVER], "primary wrapped DEK round-trips");
        PASS([gotBlock isEqualToData:block], "additional-recipients block round-trips byte-identically");
        [fr close];
        fdRm(src); fdRm(dst);
    }

    // ── single-recipient unchanged (no _recipients attr emitted) ──
    {
        NSString *src = fdPath(@"single_src.tio"); fdRm(src);
        NSError *err = nil;
        PASS(buildFixture(src, &err), "FD1 single-recipient fixture built");

        TTIOHDF5File *fw = [TTIOHDF5File openAtPath:src error:&err];
        id<TTIOStorageGroup> sig = openSignalChannels(fw);
        NSString *fc = firstChannel(sig);
        [sig setAttributeValue:SERVER forName:[NSString stringWithFormat:@"%@_wrapped_dek", fc] error:NULL];
        [sig setAttributeValue:@"aes-256-gcm" forName:[NSString stringWithFormat:@"%@_kek_algorithm", fc] error:NULL];
        [fw close];

        NSMutableData *streamBuf = [NSMutableData data];
        TTIOTransportWriter *writer = [[TTIOTransportWriter alloc] initWithMutableData:streamBuf];
        PASS([TTIOEncryptedTransport writeEncryptedDataset:src writer:writer providerName:nil error:&err],
             "writeEncryptedDataset (single) succeeds");
        [writer close];

        NSString *dst = fdPath(@"single_dst.tio"); fdRm(dst);
        PASS([TTIOEncryptedTransport readEncryptedToPath:dst fromStream:streamBuf providerName:nil error:&err],
             "readEncryptedToPath (single) succeeds");

        TTIOHDF5File *fr = [TTIOHDF5File openReadOnlyAtPath:dst error:&err];
        id<TTIOStorageGroup> dsig = openSignalChannels(fr);
        NSString *dfc = firstChannel(dsig);
        NSData *gotPrimary = [dsig attributeValueForName:[NSString stringWithFormat:@"%@_wrapped_dek", dfc] error:NULL];
        PASS([gotPrimary isEqualToData:SERVER], "single primary wrapped DEK round-trips");
        NSString *recipientsAttr = [NSString stringWithFormat:@"%@_wrapped_dek_recipients", dfc];
        BOOL hasRecipientsAttr = [dsig hasAttributeNamed:recipientsAttr];
        PASS(!hasRecipientsAttr,
             "no _wrapped_dek_recipients attr emitted for single recipient");
        [fr close];
        fdRm(src); fdRm(dst);
    }
}
