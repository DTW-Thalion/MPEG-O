/*
 * TestTransportCodec — v0.10 M67.
 *
 * Covers:
 *   - PacketHeader encode/decode round-trip and magic/version guards
 *   - AccessUnit encode/decode round-trip (with and without channels)
 *   - CRC-32C known vectors (matches Python google-crc32c output)
 *   - File → transport → file end-to-end via a synthetic dataset
 *   - Ordering enforcement: AU before StreamHeader, non-monotonic AU
 *
 * Cross-language equivalent:
 *   python/tests/test_transport_packets.py
 *   python/tests/test_transport_codec.py
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <string.h>
#import <unistd.h>

#import "Transport/MPGOTransportPacket.h"
#import "Transport/MPGOAccessUnit.h"
#import "Transport/MPGOTransportWriter.h"
#import "Transport/MPGOTransportReader.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOWrittenRun.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Spectra/MPGOSpectrum.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEnums.h"

static NSString *tmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_m67_%d_%@",
            (int)getpid(), suffix];
}

static void rmFile(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static NSData *float64LEBuffer(const double *values, NSUInteger count)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:count * 8];
    for (NSUInteger i = 0; i < count; i++) {
        double v = values[i];
        uint64_t bits;
        memcpy(&bits, &v, 8);
        uint8_t buf[8];
        for (int k = 0; k < 8; k++) buf[k] = (uint8_t)((bits >> (8 * k)) & 0xFFu);
        [d appendBytes:buf length:8];
    }
    return d;
}

static NSData *int32LEArray(const int32_t *values, NSUInteger count)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:count * 4];
    for (NSUInteger i = 0; i < count; i++) {
        int32_t v = values[i];
        [d appendBytes:&v length:4];
    }
    return d;
}

static NSData *uint32LEArray(const uint32_t *values, NSUInteger count)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:count * 4];
    for (NSUInteger i = 0; i < count; i++) {
        uint32_t v = values[i];
        [d appendBytes:&v length:4];
    }
    return d;
}

static NSData *uint64LEArray(const uint64_t *values, NSUInteger count)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:count * 8];
    for (NSUInteger i = 0; i < count; i++) {
        uint64_t v = values[i];
        [d appendBytes:&v length:8];
    }
    return d;
}

// Build a minimal 3-spectrum MS .mpgo for round-trip testing.
static BOOL buildFixture(NSString *path, NSError **error)
{
    NSUInteger n = 3;
    NSUInteger p = 4;
    NSUInteger total = n * p;

    double *mzArr = calloc(total, sizeof(double));
    double *intArr = calloc(total, sizeof(double));
    for (NSUInteger i = 0; i < total; i++) {
        mzArr[i] = 100.0 + (double)i;
        intArr[i] = 1000.0 * (double)(i + 1);
    }

    NSData *mzData = float64LEBuffer(mzArr, total);
    NSData *intData = float64LEBuffer(intArr, total);

    uint64_t offsets[3] = {0, 4, 8};
    uint32_t lengths[3] = {4, 4, 4};
    double rts[3] = {1.0, 2.0, 3.0};
    int32_t msLevels[3] = {1, 2, 1};
    int32_t pols[3] = {(int32_t)MPGOPolarityPositive,
                       (int32_t)MPGOPolarityPositive,
                       (int32_t)MPGOPolarityPositive};
    double pmzs[3] = {0.0, 500.25, 0.0};
    int32_t pcs[3] = {0, 2, 0};
    double bpis[3];
    for (NSUInteger i = 0; i < n; i++) {
        double best = 0.0;
        for (NSUInteger k = 0; k < p; k++) {
            double v = intArr[i * p + k];
            if (v > best) best = v;
        }
        bpis[i] = best;
    }
    free(mzArr); free(intArr);

    MPGOWrittenRun *run =
        [[MPGOWrittenRun alloc]
            initWithSpectrumClassName:@"MPGOMassSpectrum"
                      acquisitionMode:(int64_t)MPGOAcquisitionModeMS1DDA
                          channelData:@{@"mz": mzData, @"intensity": intData}
                              offsets:uint64LEArray(offsets, 3)
                              lengths:uint32LEArray(lengths, 3)
                       retentionTimes:float64LEBuffer(rts, 3)
                             msLevels:int32LEArray(msLevels, 3)
                           polarities:int32LEArray(pols, 3)
                         precursorMzs:float64LEBuffer(pmzs, 3)
                     precursorCharges:int32LEArray(pcs, 3)
                  basePeakIntensities:float64LEBuffer(bpis, 3)];
    return [MPGOSpectralDataset writeMinimalToPath:path
                                              title:@"M67 round-trip fixture"
                                 isaInvestigationId:@"ISA-M67-TEST"
                                             msRuns:@{@"run_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

void testTransportCodec(void)
{
    // ── 1. Packet header round-trip ────────────────────────────────
    {
        MPGOTransportPacketHeader *h =
            [[MPGOTransportPacketHeader alloc]
                initWithPacketType:MPGOTransportPacketAccessUnit
                              flags:(uint16_t)MPGOTransportPacketFlagHasChecksum
                          datasetId:42
                         auSequence:12345
                      payloadLength:9999
                        timestampNs:1700000000000000000ULL];
        NSData *raw = [h encode];
        PASS(raw.length == 24, "packet header encodes to 24 bytes");

        NSError *err = nil;
        MPGOTransportPacketHeader *d =
            [MPGOTransportPacketHeader decodeFromBytes:(const uint8_t *)raw.bytes
                                                  length:raw.length
                                                   error:&err];
        PASS(d != nil && d.packetType == MPGOTransportPacketAccessUnit,
             "packet type round-trips");
        PASS(d.datasetId == 42 && d.auSequence == 12345 && d.payloadLength == 9999,
             "IDs + payload length round-trip");
        PASS(d.timestampNs == 1700000000000000000ULL,
             "timestamp round-trips");
    }

    // ── 2. Bad magic is rejected ────────────────────────────────────
    {
        uint8_t bad[24] = {'X','X', 0x01, 0x01};
        NSError *err = nil;
        MPGOTransportPacketHeader *d =
            [MPGOTransportPacketHeader decodeFromBytes:bad length:24 error:&err];
        PASS(d == nil, "bad magic: returns nil");
        PASS(err != nil && err.code == MPGOTransportErrorBadMagic,
             "bad magic: error code BadMagic");
    }

    // ── 3. CRC-32C known vector ────────────────────────────────────
    {
        // "123456789" → 0xE3069283 per Castagnoli reference
        const uint8_t v[] = "123456789";
        uint32_t crc = MPGOTransportCRC32C(v, 9);
        PASS(crc == 0xE3069283u,
             "CRC-32C of '123456789' == 0xE3069283");

        uint32_t empty = MPGOTransportCRC32C((const uint8_t *)"", 0);
        PASS(empty == 0, "CRC-32C of empty == 0");
    }

    // ── 4. AccessUnit round-trip ────────────────────────────────────
    {
        double mzVals[3] = {100.0, 200.0, 300.0};
        double intVals[3] = {1000.0, 2000.0, 3000.0};
        MPGOTransportChannelData *mz =
            [[MPGOTransportChannelData alloc]
                initWithName:@"mz"
                   precision:MPGOPrecisionFloat64
                 compression:MPGOCompressionNone
                   nElements:3
                        data:float64LEBuffer(mzVals, 3)];
        MPGOTransportChannelData *intensity =
            [[MPGOTransportChannelData alloc]
                initWithName:@"intensity"
                   precision:MPGOPrecisionFloat64
                 compression:MPGOCompressionNone
                   nElements:3
                        data:float64LEBuffer(intVals, 3)];
        MPGOAccessUnit *au =
            [[MPGOAccessUnit alloc]
                initWithSpectrumClass:0
                      acquisitionMode:0
                              msLevel:2
                             polarity:0
                        retentionTime:123.456
                          precursorMz:500.25
                      precursorCharge:2
                          ionMobility:0.0
                    basePeakIntensity:1.0e6
                             channels:@[mz, intensity]
                               pixelX:0 pixelY:0 pixelZ:0];
        NSData *raw = [au encode];
        NSError *err = nil;
        MPGOAccessUnit *d =
            [MPGOAccessUnit decodeFromBytes:(const uint8_t *)raw.bytes
                                      length:raw.length
                                       error:&err];
        PASS(d != nil, "AccessUnit decodes");
        PASS(d.spectrumClass == 0 && d.msLevel == 2 && d.polarity == 0,
             "AU scalar fields round-trip");
        PASS(d.retentionTime == 123.456 && d.precursorMz == 500.25
                && d.precursorCharge == 2 && d.basePeakIntensity == 1.0e6,
             "AU f64 / u8 fields round-trip");
        PASS(d.channels.count == 2
             && [d.channels[0].name isEqualToString:@"mz"]
             && [d.channels[1].name isEqualToString:@"intensity"],
             "AU channels round-trip with names");
    }

    // ── 5. MSImagePixel AU round-trip ──────────────────────────────
    {
        double one = 500.0;
        MPGOTransportChannelData *ch =
            [[MPGOTransportChannelData alloc]
                initWithName:@"intensity"
                   precision:MPGOPrecisionFloat64
                 compression:MPGOCompressionNone
                   nElements:1
                        data:float64LEBuffer(&one, 1)];
        MPGOAccessUnit *au =
            [[MPGOAccessUnit alloc]
                initWithSpectrumClass:4
                      acquisitionMode:(uint8_t)MPGOAcquisitionModeImaging
                              msLevel:1
                             polarity:0
                        retentionTime:0.0
                          precursorMz:0.0
                      precursorCharge:0
                          ionMobility:0.0
                    basePeakIntensity:500.0
                             channels:@[ch]
                               pixelX:10 pixelY:20 pixelZ:0];
        NSError *err = nil;
        MPGOAccessUnit *d =
            [MPGOAccessUnit decodeFromBytes:(const uint8_t *)[au encode].bytes
                                      length:[au encode].length
                                       error:&err];
        PASS(d != nil && d.pixelX == 10 && d.pixelY == 20 && d.pixelZ == 0,
             "MSImagePixel AU: pixel coordinates round-trip");
    }

    // ── 6. End-to-end file → stream → file round-trip ──────────────
    {
        NSString *srcPath = tmpPath(@"src.mpgo");
        NSString *streamPath = tmpPath(@"stream.mots");
        NSString *rtPath = tmpPath(@"rt.mpgo");
        rmFile(srcPath); rmFile(streamPath); rmFile(rtPath);

        NSError *err = nil;
        BOOL ok = buildFixture(srcPath, &err);
        PASS(ok, "fixture write succeeds");

        MPGOSpectralDataset *src =
            [MPGOSpectralDataset readFromFilePath:srcPath error:&err];
        PASS(src != nil, "fixture reopens");

        MPGOTransportWriter *tw =
            [[MPGOTransportWriter alloc] initWithOutputPath:streamPath];
        BOOL wrote = [tw writeDataset:src error:&err];
        [tw close];
        PASS(wrote, "transport write succeeds");
        PASS([[NSFileManager defaultManager] fileExistsAtPath:streamPath],
             ".mots file exists");

        MPGOTransportReader *tr =
            [[MPGOTransportReader alloc] initWithInputPath:streamPath];
        NSArray *packets = [tr readAllPacketsWithError:&err];
        // Expect: StreamHeader + DatasetHeader + 3 AU + EndOfDataset + EndOfStream = 7
        PASS(packets != nil && packets.count == 7,
             "stream has 7 packets (header/ds/3xau/eod/eos)");

        BOOL rtOk = [tr writeMpgoToPath:rtPath error:&err];
        PASS(rtOk, "transport → .mpgo materialization succeeds");

        MPGOSpectralDataset *rt =
            [MPGOSpectralDataset readFromFilePath:rtPath error:&err];
        PASS(rt != nil, "round-tripped .mpgo opens");
        PASS([rt.title isEqualToString:@"M67 round-trip fixture"],
             "title preserved");
        PASS([rt.isaInvestigationId isEqualToString:@"ISA-M67-TEST"],
             "ISA investigation id preserved");
        PASS(rt.msRuns.count == 1 && rt.msRuns[@"run_0001"] != nil,
             "one MS run named run_0001");

        MPGOAcquisitionRun *rtRun = rt.msRuns[@"run_0001"];
        PASS([rtRun count] == 3, "3 spectra in round-tripped run");

        MPGOSpectrum *s0 = [rtRun objectAtIndex:1];
        PASS([s0 isKindOfClass:[MPGOMassSpectrum class]],
             "round-tripped spectrum is MPGOMassSpectrum");
        PASS(((MPGOMassSpectrum *)s0).msLevel == 2,
             "ms_level=2 on second spectrum");
        PASS(fabs(s0.scanTimeSeconds - 2.0) < 1e-9,
             "retention time preserved");
        PASS(fabs(s0.precursorMz - 500.25) < 1e-9,
             "precursor m/z preserved");

        rmFile(srcPath); rmFile(streamPath); rmFile(rtPath);
    }

    // ── 7. AU before StreamHeader is rejected ──────────────────────
    {
        NSMutableData *buf = [NSMutableData data];
        MPGOTransportWriter *tw = [[MPGOTransportWriter alloc] initWithMutableData:buf];
        // Fabricate an orphan AU by reaching through fine-grained API.
        MPGOAccessUnit *au =
            [[MPGOAccessUnit alloc]
                initWithSpectrumClass:0 acquisitionMode:0 msLevel:1
                              polarity:0 retentionTime:1.0 precursorMz:0.0
                       precursorCharge:0 ionMobility:0.0
                     basePeakIntensity:0.0
                              channels:@[]
                                pixelX:0 pixelY:0 pixelZ:0];
        NSError *err = nil;
        [tw writeAccessUnit:au datasetId:1 auSequence:0 error:&err];
        [tw writeEndOfStreamWithError:&err];

        NSString *rtPath = tmpPath(@"stream-orphan.mpgo");
        rmFile(rtPath);
        MPGOTransportReader *tr = [[MPGOTransportReader alloc] initWithData:buf];
        NSError *rtErr = nil;
        BOOL ok = [tr writeMpgoToPath:rtPath error:&rtErr];
        PASS(!ok, "orphan AU (no StreamHeader): rejected");
        PASS(rtErr && rtErr.code == MPGOTransportErrorMissingStreamHeader,
             "orphan AU: error code MissingStreamHeader");
        rmFile(rtPath);
    }
}
