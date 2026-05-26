/*
 * TestTransportDatasetProvenance.m — Task 3.5 of transport-spec v0.11.
 *
 * Exercises DATASET_PROVENANCE (0x18) writer + reader. Wire layout
 * per transport-spec §4.21: single packet, `uint32 record_count`
 * prefix + N records, per record:
 *   int64  timestamp_unix
 *   uint16 software_length      + UTF-8 bytes
 *   uint16 parameters_length    + UTF-8 JSON
 *   uint16 input_refs_length    + UTF-8 CSV
 *   uint16 output_refs_length   + UTF-8 CSV
 * All LE.
 *
 * Cross-language parity:
 *   Java TransportDatasetProvenanceTest (commit 563e09c3)
 *   Python tests/test_transport_dataset_provenance.py (commit 434d45a6)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOTransportReader+Internal.h"
#import "Transport/TTIOTransportWriter.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOProvenanceRecord.h"
#include <unistd.h>

static NSString *makeTempPathP(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_prov_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:base];
}

// ---------- LE readers ----------

static uint16_t leU16P(const uint8_t *b)
{
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}

static uint32_t leU32P(const uint8_t *b)
{
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

static int64_t leI64P(const uint8_t *b)
{
    uint64_t lo = (uint64_t)leU32P(b);
    uint64_t hi = (uint64_t)leU32P(b + 4);
    return (int64_t)(lo | (hi << 32));
}

static NSString *readLEStrP(const uint8_t *bytes, NSUInteger *off, uint16_t *outLen)
{
    uint16_t len = leU16P(&bytes[*off]); *off += 2;
    if (outLen) *outLen = len;
    NSString *s = [[NSString alloc] initWithBytes:&bytes[*off]
                                            length:len
                                          encoding:NSUTF8StringEncoding] ?: @"";
    *off += len;
    return s;
}

// ---------- writer low-level: zero records is a no-op ----------

static void testWriteDatasetProvenanceZeroRecordsEmitsNoPacket(void)
{
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"prov-empty"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.5 zero: StreamHeader");
    PASS([w writeDatasetProvenance:@[] error:&err],
         "3.5 zero: writeDatasetProvenance:[] succeeded");
    PASS([w writeEndOfStreamWithError:&err], "3.5 zero: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records.count == 2,
         "3.5 zero: 0 records -> only StreamHeader + EndOfStream");
    for (TTIOTransportPacketRecord *rec in records) {
        PASS(rec.header.packetType
                != TTIOTransportPacketDatasetProvenance,
             "3.5 zero: no 0x18 packet emitted");
    }
}

// ---------- writer low-level: single record round-trips ----------

static TTIOProvenanceRecord *makeRecord(int64_t ts,
                                          NSString *software,
                                          NSDictionary *params,
                                          NSArray *inputs,
                                          NSArray *outputs)
{
    return [[TTIOProvenanceRecord alloc]
                initWithInputRefs:inputs
                         software:software
                       parameters:params
                       outputRefs:outputs
                    timestampUnix:ts];
}

static void testWriteDatasetProvenanceSingleRecord(void)
{
    TTIOProvenanceRecord *r1 = makeRecord(
        1700000000LL,
        @"TTI-O ObjC 1.0.0",
        @{@"threshold": @"0.5"},
        @[@"file:///in.raw", @"file:///in2.raw"],
        @[@"file:///out.tio"]);

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"prov-one"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.5 one: StreamHeader");
    PASS([w writeDatasetProvenance:@[r1] error:&err],
         "3.5 one: writeDatasetProvenance emitted");
    PASS([w writeEndOfStreamWithError:&err], "3.5 one: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records.count == 3,
         "3.5 one: StreamHeader + DatasetProvenance + EndOfStream");
    PASS(records[1].header.packetType
            == TTIOTransportPacketDatasetProvenance,
         "3.5 one: middle packet is DATASET_PROVENANCE (0x18)");

    NSData *payload = records[1].payload;
    const uint8_t *bytes = payload.bytes;
    NSUInteger off = 0;
    uint32_t count = leU32P(&bytes[off]); off += 4;
    PASS(count == 1, "3.5 one: record_count == 1");
    int64_t ts = leI64P(&bytes[off]); off += 8;
    PASS(ts == 1700000000LL, "3.5 one: timestamp_unix LE round-trips");
    uint16_t softLen = 0;
    NSString *software = readLEStrP(bytes, &off, &softLen);
    PASS([software isEqualToString:@"TTI-O ObjC 1.0.0"],
         "3.5 one: software string decoded");
    NSString *paramsJson = readLEStrP(bytes, &off, NULL);
    PASS([paramsJson isEqualToString:@"{\"threshold\":\"0.5\"}"],
         "3.5 one: parameters_json sorted-keys + no spaces");
    NSString *inputsCsv = readLEStrP(bytes, &off, NULL);
    PASS([inputsCsv isEqualToString:@"file:///in.raw,file:///in2.raw"],
         "3.5 one: input_refs comma-joined");
    NSString *outputsCsv = readLEStrP(bytes, &off, NULL);
    PASS([outputsCsv isEqualToString:@"file:///out.tio"],
         "3.5 one: output_refs comma-joined");
    PASS(off == payload.length,
         "3.5 one: no trailing bytes in payload");
}

// ---------- writer low-level: 3 records preserve order ----------

static void testWriteDatasetProvenanceThreeRecordsPreservesOrder(void)
{
    TTIOProvenanceRecord *r1 = makeRecord(
        1700000000LL, @"step A", @{@"a": @"1"},
        @[@"file:///in1"], @[@"file:///out1"]);
    TTIOProvenanceRecord *r2 = makeRecord(
        1700000100LL, @"step B", @{},
        @[], @[]);
    TTIOProvenanceRecord *r3 = makeRecord(
        1700000200LL, @"step C", @{@"k": @"v"},
        @[@"file:///x", @"file:///y"], @[@"file:///z"]);

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"prov-three"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.5 three: StreamHeader");
    NSArray *threeRecs = @[r1, r2, r3];
    PASS([w writeDatasetProvenance:threeRecs error:&err],
         "3.5 three: writeDatasetProvenance(3 records)");
    PASS([w writeEndOfStreamWithError:&err], "3.5 three: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records[1].header.packetType
            == TTIOTransportPacketDatasetProvenance,
         "3.5 three: middle packet is DATASET_PROVENANCE");

    NSData *payload = records[1].payload;
    const uint8_t *bytes = payload.bytes;
    NSUInteger off = 0;
    uint32_t count = leU32P(&bytes[off]); off += 4;
    PASS(count == 3, "3.5 three: record_count == 3");

    // Record 0
    int64_t ts0 = leI64P(&bytes[off]); off += 8;
    PASS(ts0 == 1700000000LL, "3.5 three: record 0 timestamp");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"step A"],
         "3.5 three: record 0 software");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"{\"a\":\"1\"}"],
         "3.5 three: record 0 params");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"file:///in1"],
         "3.5 three: record 0 inputs");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"file:///out1"],
         "3.5 three: record 0 outputs");

    // Record 1 — empty params + empty inputs + empty outputs
    int64_t ts1 = leI64P(&bytes[off]); off += 8;
    PASS(ts1 == 1700000100LL, "3.5 three: record 1 timestamp");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"step B"],
         "3.5 three: record 1 software");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"{}"],
         "3.5 three: empty params rendered as '{}'");
    uint16_t inLen1 = 0;
    NSString *in1 = readLEStrP(bytes, &off, &inLen1);
    PASS([in1 isEqualToString:@""] && inLen1 == 0,
         "3.5 three: empty input_refs encoded as zero-length string");
    uint16_t outLen1 = 0;
    NSString *out1 = readLEStrP(bytes, &off, &outLen1);
    PASS([out1 isEqualToString:@""] && outLen1 == 0,
         "3.5 three: empty output_refs encoded as zero-length string");

    // Record 2
    int64_t ts2 = leI64P(&bytes[off]); off += 8;
    PASS(ts2 == 1700000200LL, "3.5 three: record 2 timestamp");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"step C"],
         "3.5 three: record 2 software");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"{\"k\":\"v\"}"],
         "3.5 three: record 2 params");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"file:///x,file:///y"],
         "3.5 three: record 2 inputs comma-joined");
    PASS([readLEStrP(bytes, &off, NULL) isEqualToString:@"file:///z"],
         "3.5 three: record 2 outputs");

    PASS(off == payload.length,
         "3.5 three: payload size accounted for by 3 records");
}

// ---------- writeDataset emits 0x18 when records present ----------

static NSString *buildProvenanceOnlyTio(NSString *base, NSError **err)
{
    NSString *path = makeTempPathP(base);
    unlink([path fileSystemRepresentation]);
    TTIOProvenanceRecord *r1 = makeRecord(
        1700000000LL, @"TTI-O ObjC 1.0.0", @{@"mode": @"strict"},
        @[@"file:///in.raw"], @[@"file:///out.tio"]);
    TTIOProvenanceRecord *r2 = makeRecord(
        1700000100LL, @"downstream step", @{},
        @[], @[@"file:///final.tio"]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"provenance_only"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:@[r1, r2]
                                                  error:err];
    if (!ok) return nil;
    return path;
}

static void testWriteDatasetEmitsDatasetProvenanceWhenPresent(void)
{
    NSError *err = nil;
    NSString *src = buildProvenanceOnlyTio(@"src_prov", &err);
    PASS(src != nil && err == nil, "3.5 wd: built provenance-only fixture");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.5 wd: opened fixture dataset");
    PASS(ds.provenanceRecords.count == 2,
         "3.5 wd: fixture has 2 provenance records");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.5 wd: writeDataset on provenance-bearing .tio");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records != nil, "3.5 wd: reader parsed stream");

    NSString *sh = [[NSString alloc] initWithData:records[0].payload
                                          encoding:NSUTF8StringEncoding];
    PASS(sh != nil && [sh containsString:@"transport_v0_11"],
         "3.5 wd: StreamHeader carries transport_v0_11 feature flag");

    int provCount = 0;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketDatasetProvenance) {
            provCount++;
        }
    }
    PASS(provCount == 1,
         "3.5 wd: exactly one DATASET_PROVENANCE packet emitted");

    [ds closeFile];
    unlink([src fileSystemRepresentation]);
}

// ---------- writeDataset on no-prov .tio emits no 0x18 ----------

static void testWriteDatasetNoPacketWhenProvenanceEmpty(void)
{
    NSError *err = nil;
    NSString *src = makeTempPathP(@"plain_noprov");
    unlink([src fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:src
                                                  title:@"plain"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "3.5 noprov: minimal .tio created");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil && ds.provenanceRecords.count == 0,
         "3.5 noprov: dataset has no provenance");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.5 noprov: writeDataset on no-prov .tio");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    BOOL sawProv = NO;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketDatasetProvenance) {
            sawProv = YES;
            break;
        }
    }
    PASS(!sawProv,
         "3.5 noprov: no-prov dataset emits no 0x18 packet");

    [ds closeFile];
    unlink([src fileSystemRepresentation]);
}

// ---------- end-to-end round-trip via materialize ----------

static void testDatasetProvenanceRoundTripsViaMaterialize(void)
{
    NSError *err = nil;
    NSString *src = buildProvenanceOnlyTio(@"src_rt", &err);
    PASS(src != nil, "3.5 rt: built source");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.5 rt: opened source");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err], "3.5 rt: writeDataset");

    NSString *rt = makeTempPathP(@"rt");
    unlink([rt fileSystemRepresentation]);
    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([r writeTtioToPath:rt error:&err] && err == nil,
         "3.5 rt: writeTtioToPath materialised");

    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:rt error:&err];
    PASS(back != nil, "3.5 rt: re-opened round-trip .tio");
    PASS(back.provenanceRecords.count == ds.provenanceRecords.count,
         "3.5 rt: round-trip record count matches source");

    NSArray<TTIOProvenanceRecord *> *provA = ds.provenanceRecords;
    NSArray<TTIOProvenanceRecord *> *provB = back.provenanceRecords;
    for (NSUInteger i = 0; i < MIN(provA.count, provB.count); i++) {
        TTIOProvenanceRecord *a = provA[i];
        TTIOProvenanceRecord *b = provB[i];
        PASS(a.timestampUnix == b.timestampUnix,
             "3.5 rt: timestamp matches");
        PASS([a.software isEqualToString:b.software ?: @""],
             "3.5 rt: software matches");
        PASS([a.inputRefs isEqualToArray:(b.inputRefs ?: @[])],
             "3.5 rt: inputRefs matches");
        PASS([a.outputRefs isEqualToArray:(b.outputRefs ?: @[])],
             "3.5 rt: outputRefs matches");
    }

    [ds closeFile];
    [back closeFile];
    unlink([src fileSystemRepresentation]);
    unlink([rt fileSystemRepresentation]);
}

void testTransportDatasetProvenance(void);
void testTransportDatasetProvenance(void)
{
    testWriteDatasetProvenanceZeroRecordsEmitsNoPacket();
    testWriteDatasetProvenanceSingleRecord();
    testWriteDatasetProvenanceThreeRecordsPreservesOrder();
    testWriteDatasetEmitsDatasetProvenanceWhenPresent();
    testWriteDatasetNoPacketWhenProvenanceEmpty();
    testDatasetProvenanceRoundTripsViaMaterialize();
}
