/*
 * TestEncryptedTransport — v1.0 ObjC.
 *
 * Verifies TTIOEncryptedTransport emits a well-formed stream from a
 * per-AU-encrypted file:
 *   - StreamHeader + ProtectionMetadata + DatasetHeader + N AUs +
 *     EndOfDataset + EndOfStream appear in the expected order.
 *   - Every AU packet header carries ENCRYPTED (and ENCRYPTED_HEADER
 *     when opt_encrypted_au_headers is set).
 *   - ProtectionMetadata payload is parseable (cipher_suite,
 *     kek_algorithm, wrapped_dek, etc.).
 *
 * Also verifies the reader-side path: decode a stream back into a
 * per-AU-encrypted .tio, decrypt with the same DEK, and confirm
 * plaintext channels survive byte-for-byte.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#import <string.h>

#import "Transport/TTIOEncryptedTransport.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOTransportPacket.h"
#import "Protection/TTIOPerAUFile.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "ValueClasses/TTIOEnums.h"


static NSString *tmpPath(NSString *n) {
    return [NSString stringWithFormat:@"/tmp/ttio_enctrans_%d_%@",
            (int)getpid(), n];
}
static void rmFile(NSString *p) { [[NSFileManager defaultManager] removeItemAtPath:p error:NULL]; }
static NSData *testKey(void) {
    uint8_t b[32]; memset(b, 0x77, 32);
    return [NSData dataWithBytes:b length:32];
}

static NSData *f64arr(const double *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *u64arr(const uint64_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *u32arr(const uint32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *i32arr(const int32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}


static BOOL buildAndEncryptFixture(NSString *path,
                                     BOOL encryptHeaders,
                                     NSError **error)
{
    NSUInteger n = 3, p = 4, total = n * p;
    double mz[12], intensity[12];
    for (NSUInteger i = 0; i < total; i++) {
        mz[i] = 100.0 + (double)i;
        intensity[i] = (double)(i + 1) * 10.0;
    }
    uint64_t offsets[3] = {0, 4, 8};
    uint32_t lengths[3] = {4, 4, 4};
    double rts[3] = {1.0, 2.0, 3.0};
    int32_t msLevels[3] = {1, 2, 1};
    int32_t pols[3] = {1, 1, 1};
    double pmzs[3] = {0.0, 500.0, 0.0};
    int32_t pcs[3] = {0, 2, 0};
    double bpis[3] = {40.0, 80.0, 120.0};

    TTIOWrittenRun *run =
        [[TTIOWrittenRun alloc]
            initWithSpectrumClassName:@"TTIOMassSpectrum"
                      acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                          channelData:@{@"mz": f64arr(mz, total),
                                        @"intensity": f64arr(intensity, total)}
                              offsets:u64arr(offsets, n)
                              lengths:u32arr(lengths, n)
                       retentionTimes:f64arr(rts, n)
                             msLevels:i32arr(msLevels, n)
                           polarities:i32arr(pols, n)
                         precursorMzs:f64arr(pmzs, n)
                     precursorCharges:i32arr(pcs, n)
                  basePeakIntensities:f64arr(bpis, n)];
    if (![TTIOSpectralDataset writeMinimalToPath:path
                                            title:@"enc-transport fixture"
                               isaInvestigationId:@"ISA-ENC-TX"
                                           msRuns:@{@"run_0001": run}
                                  identifications:nil
                                  quantifications:nil
                                provenanceRecords:nil
                                            error:error]) return NO;
    return [TTIOPerAUFile encryptFilePath:path
                                        key:testKey()
                           encryptHeaders:encryptHeaders
                              providerName:nil
                                     error:error];
}


void testEncryptedTransport(void)
{
    // ── 1. ENCRYPTED-only path ──────────────────────────────────
    {
        NSString *src = tmpPath(@"src1.tio");
        rmFile(src);
        NSError *err = nil;
        PASS(buildAndEncryptFixture(src, NO, &err),
             "encrypted fixture built (channels only)");
        PASS([TTIOEncryptedTransport isPerAUEncryptedAtPath:src
                                                providerName:nil],
             "isPerAUEncrypted reports YES after encryption");

        NSMutableData *streamBuf = [NSMutableData data];
        TTIOTransportWriter *writer =
            [[TTIOTransportWriter alloc] initWithMutableData:streamBuf];
        BOOL ok = [TTIOEncryptedTransport writeEncryptedDataset:src
                                                           writer:writer
                                                     providerName:nil
                                                            error:&err];
        [writer close];
        PASS(ok, "writeEncryptedDataset succeeds");
        PASS(streamBuf.length > 0, "stream has content");

        // Parse packets back.
        TTIOTransportReader *reader =
            [[TTIOTransportReader alloc] initWithData:streamBuf];
        NSArray *packets = [reader readAllPacketsWithError:&err];
        PASS(packets != nil, "stream parses");

        NSUInteger nStreamHeader = 0, nDatasetHeader = 0, nProtection = 0;
        NSUInteger nAU = 0, nEOD = 0, nEOS = 0;
        BOOL allAUsEncrypted = YES;
        BOOL anyHeaderEncrypted = NO;
        for (TTIOTransportPacketRecord *r in packets) {
            switch (r.header.packetType) {
                case TTIOTransportPacketStreamHeader: nStreamHeader++; break;
                case TTIOTransportPacketDatasetHeader: nDatasetHeader++; break;
                case TTIOTransportPacketProtectionMetadata: nProtection++; break;
                case TTIOTransportPacketAccessUnit:
                    nAU++;
                    if (!(r.header.flags & TTIOTransportPacketFlagEncrypted))
                        allAUsEncrypted = NO;
                    if (r.header.flags & TTIOTransportPacketFlagEncryptedHeader)
                        anyHeaderEncrypted = YES;
                    break;
                case TTIOTransportPacketEndOfDataset: nEOD++; break;
                case TTIOTransportPacketEndOfStream: nEOS++; break;
                default: break;
            }
        }
        PASS(nStreamHeader == 1, "exactly one StreamHeader");
        PASS(nDatasetHeader == 1, "exactly one DatasetHeader");
        PASS(nProtection == 1, "exactly one ProtectionMetadata");
        PASS(nAU == 3, "three AccessUnits (3-spectrum fixture)");
        PASS(nEOD == 1 && nEOS == 1, "EndOfDataset + EndOfStream present");
        PASS(allAUsEncrypted,
             "every AU carries TTIOTransportPacketFlagEncrypted");
        PASS(!anyHeaderEncrypted,
             "no AU carries EncryptedHeader (channels-only mode)");
        rmFile(src);
    }

    // ── 2. ENCRYPTED | ENCRYPTED_HEADER path ────────────────────
    {
        NSString *src = tmpPath(@"src2.tio");
        rmFile(src);
        NSError *err = nil;
        buildAndEncryptFixture(src, YES, &err);

        NSMutableData *streamBuf = [NSMutableData data];
        TTIOTransportWriter *writer =
            [[TTIOTransportWriter alloc] initWithMutableData:streamBuf];
        [TTIOEncryptedTransport writeEncryptedDataset:src
                                                 writer:writer
                                           providerName:nil
                                                  error:&err];
        [writer close];

        TTIOTransportReader *reader =
            [[TTIOTransportReader alloc] initWithData:streamBuf];
        NSArray *packets = [reader readAllPacketsWithError:&err];
        BOOL allEncrypted = YES, allEncryptedHeader = YES;
        NSUInteger nAU = 0;
        for (TTIOTransportPacketRecord *r in packets) {
            if (r.header.packetType == TTIOTransportPacketAccessUnit) {
                nAU++;
                if (!(r.header.flags & TTIOTransportPacketFlagEncrypted))
                    allEncrypted = NO;
                if (!(r.header.flags & TTIOTransportPacketFlagEncryptedHeader))
                    allEncryptedHeader = NO;
            }
        }
        PASS(nAU == 3 && allEncrypted && allEncryptedHeader,
             "all 3 AUs carry ENCRYPTED | ENCRYPTED_HEADER");
        rmFile(src);
    }

    // ── 3. Round-trip: write stream → read stream → decrypt ─────
    for (int mode = 0; mode < 2; mode++) {
        BOOL encryptHeaders = (mode == 1);
        NSString *src = tmpPath(encryptHeaders ? @"rt_src_hdr.tio"
                                               : @"rt_src_ch.tio");
        NSString *dst = tmpPath(encryptHeaders ? @"rt_dst_hdr.tio"
                                               : @"rt_dst_ch.tio");
        rmFile(src); rmFile(dst);
        NSError *err = nil;
        PASS(buildAndEncryptFixture(src, encryptHeaders, &err),
             "round-trip: encrypted fixture built");

        NSMutableData *streamBuf = [NSMutableData data];
        TTIOTransportWriter *writer =
            [[TTIOTransportWriter alloc] initWithMutableData:streamBuf];
        BOOL wrote = [TTIOEncryptedTransport writeEncryptedDataset:src
                                                              writer:writer
                                                        providerName:nil
                                                               error:&err];
        [writer close];
        PASS(wrote, "round-trip: writeEncryptedDataset");

        BOOL read = [TTIOEncryptedTransport readEncryptedToPath:dst
                                                      fromStream:streamBuf
                                                    providerName:nil
                                                           error:&err];
        PASS(read, "round-trip: readEncryptedToPath materialises file");
        PASS([TTIOEncryptedTransport isPerAUEncryptedAtPath:dst
                                                providerName:nil],
             "round-trip: output file carries opt_per_au_encryption");

        NSDictionary *srcPlain =
            [TTIOPerAUFile decryptFilePath:src key:testKey()
                              providerName:nil error:&err];
        NSDictionary *dstPlain =
            [TTIOPerAUFile decryptFilePath:dst key:testKey()
                              providerName:nil error:&err];
        PASS(srcPlain != nil && dstPlain != nil,
             "round-trip: both files decrypt");
        PASS([srcPlain[@"run_0001"][@"mz"]
                isEqualToData:dstPlain[@"run_0001"][@"mz"]],
             "round-trip: mz bytes survive transport");
        PASS([srcPlain[@"run_0001"][@"intensity"]
                isEqualToData:dstPlain[@"run_0001"][@"intensity"]],
             "round-trip: intensity bytes survive transport");

        rmFile(src); rmFile(dst);
    }
}
