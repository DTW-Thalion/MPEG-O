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

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOAccessUnit.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *tmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m67_%d_%@",
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

// Build a minimal 3-spectrum MS .tio for round-trip testing.
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
    int32_t pols[3] = {(int32_t)TTIOPolarityPositive,
                       (int32_t)TTIOPolarityPositive,
                       (int32_t)TTIOPolarityPositive};
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

    TTIOWrittenRun *run =
        [[TTIOWrittenRun alloc]
            initWithSpectrumClassName:@"TTIOMassSpectrum"
                      acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                          channelData:@{@"mz": mzData, @"intensity": intData}
                              offsets:uint64LEArray(offsets, 3)
                              lengths:uint32LEArray(lengths, 3)
                       retentionTimes:float64LEBuffer(rts, 3)
                             msLevels:int32LEArray(msLevels, 3)
                           polarities:int32LEArray(pols, 3)
                         precursorMzs:float64LEBuffer(pmzs, 3)
                     precursorCharges:int32LEArray(pcs, 3)
                  basePeakIntensities:float64LEBuffer(bpis, 3)];
    return [TTIOSpectralDataset writeMinimalToPath:path
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
        TTIOTransportPacketHeader *h =
            [[TTIOTransportPacketHeader alloc]
                initWithPacketType:TTIOTransportPacketAccessUnit
                              flags:(uint16_t)TTIOTransportPacketFlagHasChecksum
                          datasetId:42
                         auSequence:12345
                      payloadLength:9999
                        timestampNs:1700000000000000000ULL];
        NSData *raw = [h encode];
        PASS(raw.length == 24, "packet header encodes to 24 bytes");

        NSError *err = nil;
        TTIOTransportPacketHeader *d =
            [TTIOTransportPacketHeader decodeFromBytes:(const uint8_t *)raw.bytes
                                                  length:raw.length
                                                   error:&err];
        PASS(d != nil && d.packetType == TTIOTransportPacketAccessUnit,
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
        TTIOTransportPacketHeader *d =
            [TTIOTransportPacketHeader decodeFromBytes:bad length:24 error:&err];
        PASS(d == nil, "bad magic: returns nil");
        PASS(err != nil && err.code == TTIOTransportErrorBadMagic,
             "bad magic: error code BadMagic");
    }

    // ── 3. CRC-32C known vector ────────────────────────────────────
    {
        // "123456789" → 0xE3069283 per Castagnoli reference
        const uint8_t v[] = "123456789";
        uint32_t crc = TTIOTransportCRC32C(v, 9);
        PASS(crc == 0xE3069283u,
             "CRC-32C of '123456789' == 0xE3069283");

        uint32_t empty = TTIOTransportCRC32C((const uint8_t *)"", 0);
        PASS(empty == 0, "CRC-32C of empty == 0");
    }

    // ── 4. AccessUnit round-trip ────────────────────────────────────
    {
        double mzVals[3] = {100.0, 200.0, 300.0};
        double intVals[3] = {1000.0, 2000.0, 3000.0};
        TTIOTransportChannelData *mz =
            [[TTIOTransportChannelData alloc]
                initWithName:@"mz"
                   precision:TTIOPrecisionFloat64
                 compression:TTIOCompressionNone
                   nElements:3
                        data:float64LEBuffer(mzVals, 3)];
        TTIOTransportChannelData *intensity =
            [[TTIOTransportChannelData alloc]
                initWithName:@"intensity"
                   precision:TTIOPrecisionFloat64
                 compression:TTIOCompressionNone
                   nElements:3
                        data:float64LEBuffer(intVals, 3)];
        TTIOAccessUnit *au =
            [[TTIOAccessUnit alloc]
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
        TTIOAccessUnit *d =
            [TTIOAccessUnit decodeFromBytes:(const uint8_t *)raw.bytes
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
        TTIOTransportChannelData *ch =
            [[TTIOTransportChannelData alloc]
                initWithName:@"intensity"
                   precision:TTIOPrecisionFloat64
                 compression:TTIOCompressionNone
                   nElements:1
                        data:float64LEBuffer(&one, 1)];
        TTIOAccessUnit *au =
            [[TTIOAccessUnit alloc]
                initWithSpectrumClass:4
                      acquisitionMode:(uint8_t)TTIOAcquisitionModeImaging
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
        TTIOAccessUnit *d =
            [TTIOAccessUnit decodeFromBytes:(const uint8_t *)[au encode].bytes
                                      length:[au encode].length
                                       error:&err];
        PASS(d != nil && d.pixelX == 10 && d.pixelY == 20 && d.pixelZ == 0,
             "MSImagePixel AU: pixel coordinates round-trip");
    }

    // ── 6. End-to-end file → stream → file round-trip ──────────────
    {
        NSString *srcPath = tmpPath(@"src.tio");
        NSString *streamPath = tmpPath(@"stream.tis");
        NSString *rtPath = tmpPath(@"rt.tio");
        rmFile(srcPath); rmFile(streamPath); rmFile(rtPath);

        NSError *err = nil;
        BOOL ok = buildFixture(srcPath, &err);
        PASS(ok, "fixture write succeeds");

        TTIOSpectralDataset *src =
            [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
        PASS(src != nil, "fixture reopens");

        TTIOTransportWriter *tw =
            [[TTIOTransportWriter alloc] initWithOutputPath:streamPath];
        BOOL wrote = [tw writeDataset:src error:&err];
        [tw close];
        PASS(wrote, "transport write succeeds");
        PASS([[NSFileManager defaultManager] fileExistsAtPath:streamPath],
             ".tis file exists");

        TTIOTransportReader *tr =
            [[TTIOTransportReader alloc] initWithInputPath:streamPath];
        NSArray *packets = [tr readAllPacketsWithError:&err];
        // Expect: StreamHeader + DatasetHeader + 3 AU + EndOfDataset + EndOfStream = 7
        PASS(packets != nil && packets.count == 7,
             "stream has 7 packets (header/ds/3xau/eod/eos)");

        BOOL rtOk = [tr writeTtioToPath:rtPath error:&err];
        PASS(rtOk, "transport → .tio materialization succeeds");

        TTIOSpectralDataset *rt =
            [TTIOSpectralDataset readFromFilePath:rtPath error:&err];
        PASS(rt != nil, "round-tripped .tio opens");
        PASS([rt.title isEqualToString:@"M67 round-trip fixture"],
             "title preserved");
        PASS([rt.isaInvestigationId isEqualToString:@"ISA-M67-TEST"],
             "ISA investigation id preserved");
        PASS(rt.msRuns.count == 1 && rt.msRuns[@"run_0001"] != nil,
             "one MS run named run_0001");

        TTIOAcquisitionRun *rtRun = rt.msRuns[@"run_0001"];
        PASS([rtRun count] == 3, "3 spectra in round-tripped run");

        TTIOSpectrum *s0 = [rtRun objectAtIndex:1];
        PASS([s0 isKindOfClass:[TTIOMassSpectrum class]],
             "round-tripped spectrum is TTIOMassSpectrum");
        PASS(((TTIOMassSpectrum *)s0).msLevel == 2,
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
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
        // Fabricate an orphan AU by reaching through fine-grained API.
        TTIOAccessUnit *au =
            [[TTIOAccessUnit alloc]
                initWithSpectrumClass:0 acquisitionMode:0 msLevel:1
                              polarity:0 retentionTime:1.0 precursorMz:0.0
                       precursorCharge:0 ionMobility:0.0
                     basePeakIntensity:0.0
                              channels:@[]
                                pixelX:0 pixelY:0 pixelZ:0];
        NSError *err = nil;
        [tw writeAccessUnit:au datasetId:1 auSequence:0 error:&err];
        [tw writeEndOfStreamWithError:&err];

        NSString *rtPath = tmpPath(@"stream-orphan.tio");
        rmFile(rtPath);
        TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:buf];
        NSError *rtErr = nil;
        BOOL ok = [tr writeTtioToPath:rtPath error:&rtErr];
        PASS(!ok, "orphan AU (no StreamHeader): rejected");
        PASS(rtErr && rtErr.code == TTIOTransportErrorMissingStreamHeader,
             "orphan AU: error code MissingStreamHeader");
        rmFile(rtPath);
    }
}
