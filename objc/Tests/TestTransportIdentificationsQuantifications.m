/*
 * TestTransportIdentificationsQuantifications.m — Task 3.7 of
 * transport-spec v0.11.
 *
 * Exercises IDENTIFICATIONS_TABLE (0x16) and QUANTIFICATIONS_TABLE
 * (0x17) writer + reader. Both packets carry a single
 * length-prefixed Apache Arrow IPC stream.
 *
 * Wire layout per transport-spec §4.19 / §4.20:
 *   uint32 arrow_ipc_length (LE)
 *   bytes  arrow_ipc[arrow_ipc_length]
 *
 * Cross-language parity:
 *   Java TransportIdentificationsQuantificationsTest (commit a6faab16)
 *   Python tests/test_transport_identifications_quantifications.py
 *     (commit 150552b6)
 *
 * Note: the Arrow IPC payload bytes are LOGICALLY equivalent across
 * SDKs but NOT byte-identical -- each Arrow binding produces a
 * slightly different flatbuffer envelope. Round-trip equivalence
 * (decode of our own bytes) is the local contract; cross-SDK decode
 * is exercised by the conformance suite.
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
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#include <unistd.h>

// -------- helpers ----------------------------------------------------------

static NSString *makeTempPathIQ(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_iq_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:base];
}

static NSArray<TTIOIdentification *> *buildIdentificationsFixture(void)
{
    TTIOIdentification *r1 = [[TTIOIdentification alloc]
        initWithRunName:@"run1"
          spectrumIndex:42
         chemicalEntity:@"CompoundA"
        confidenceScore:0.91
          evidenceChain:@[@"e1", @"e2"]];
    TTIOIdentification *r2 = [[TTIOIdentification alloc]
        initWithRunName:@"run1"
          spectrumIndex:43
         chemicalEntity:@"CompoundB"
        confidenceScore:0.85
          evidenceChain:@[@"e3"]];
    TTIOIdentification *r3 = [[TTIOIdentification alloc]
        initWithRunName:@"run2"
          spectrumIndex:0
         chemicalEntity:@"CHEBI:12345"
        confidenceScore:0.50
          evidenceChain:@[]];
    return @[r1, r2, r3];
}

static NSArray<TTIOQuantification *> *buildQuantificationsFixture(void)
{
    TTIOQuantification *q1 = [[TTIOQuantification alloc]
        initWithChemicalEntity:@"CompoundA"
                     sampleRef:@"sampleA"
                     abundance:123.45
           normalizationMethod:@"median"
                          unit:@"ng/mL"];
    TTIOQuantification *q2 = [[TTIOQuantification alloc]
        initWithChemicalEntity:@"CompoundB"
                     sampleRef:@"sampleB"
                     abundance:7.0
           normalizationMethod:@"TIC"
                          unit:@"counts"];
    return @[q1, q2];
}

// Make a minimal .tio carrying the given identifications + quantifications.
// Both lists may be empty (the empty-list path produces a v0.10-shaped
// .tio with no compound tables).
static NSString *writeMinimalDatasetIQ(NSString *suffix,
                                        NSArray *idents,
                                        NSArray *quants)
{
    NSString *path = makeTempPathIQ(suffix);
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"iq-fixture"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:(idents.count ? idents : nil)
                                        quantifications:(quants.count ? quants : nil)
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok && err == nil, "iq-fixture: writeMinimalToPath success");
    return path;
}

// -------- 1. identifications-only round-trip -------------------------------

static void testIdentificationsOnlyRoundTrip(void)
{
    NSArray<TTIOIdentification *> *idents = buildIdentificationsFixture();

    // Step 1: encode via the explicit writer entrypoint so we exercise
    // -writeIdentificationsTable: in isolation.
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"idents-only"
                               isaInvestigation:@""
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "3.7 idents-only: StreamHeader");
    PASS([w writeIdentificationsTable:idents error:&err],
         "3.7 idents-only: writeIdentificationsTable emitted");
    PASS([w writeEndOfStreamWithError:&err],
         "3.7 idents-only: EndOfStream");

    // Step 2: verify exactly one 0x16 packet is on the wire and no 0x17.
    TTIOTransportReader *probe =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [probe readAllPacketsWithError:&err];
    int identsCount = 0, quantsCount = 0;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketIdentificationsTable) identsCount++;
        if (rec.header.packetType
                == TTIOTransportPacketQuantificationsTable) quantsCount++;
    }
    PASS(identsCount == 1,
         "3.7 idents-only: exactly one IDENTIFICATIONS_TABLE packet");
    PASS(quantsCount == 0,
         "3.7 idents-only: zero QUANTIFICATIONS_TABLE packets");

    // Step 3: round-trip through writeTtioToPath: and re-open.
    NSString *outPath = makeTempPathIQ(@"idents-rt");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    err = nil;
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "3.7 idents-only: writeTtioToPath materialised");

    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(back != nil, "3.7 idents-only: re-opened materialised .tio");
    PASS(back.identifications.count == 3,
         "3.7 idents-only: identifications round-tripped (count=3)");
    PASS(back.quantifications.count == 0,
         "3.7 idents-only: no quantifications materialised");

    if (back.identifications.count == 3) {
        TTIOIdentification *a0 = back.identifications[0];
        PASS([a0.runName isEqualToString:@"run1"],
             "3.7 idents-only: row0 runName");
        PASS(a0.spectrumIndex == 42,
             "3.7 idents-only: row0 spectrumIndex");
        PASS([a0.chemicalEntity isEqualToString:@"CompoundA"],
             "3.7 idents-only: row0 chemicalEntity");
        PASS(a0.confidenceScore == 0.91,
             "3.7 idents-only: row0 confidenceScore");
        PASS([a0.evidenceChain isEqualToArray:(@[@"e1", @"e2"])],
             "3.7 idents-only: row0 evidenceChain");
        TTIOIdentification *a2 = back.identifications[2];
        PASS([a2.chemicalEntity isEqualToString:@"CHEBI:12345"],
             "3.7 idents-only: row2 chemicalEntity");
        PASS(a2.evidenceChain.count == 0,
             "3.7 idents-only: row2 empty evidence chain round-trips");
    }

    [back closeFile];
    unlink([outPath fileSystemRepresentation]);
}

// -------- 2. quantifications-only round-trip -------------------------------

static void testQuantificationsOnlyRoundTrip(void)
{
    NSArray<TTIOQuantification *> *quants = buildQuantificationsFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"quants-only"
                               isaInvestigation:@""
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "3.7 quants-only: StreamHeader");
    PASS([w writeQuantificationsTable:quants error:&err],
         "3.7 quants-only: writeQuantificationsTable emitted");
    PASS([w writeEndOfStreamWithError:&err],
         "3.7 quants-only: EndOfStream");

    TTIOTransportReader *probe =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [probe readAllPacketsWithError:&err];
    int identsCount = 0, quantsCount = 0;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketIdentificationsTable) identsCount++;
        if (rec.header.packetType
                == TTIOTransportPacketQuantificationsTable) quantsCount++;
    }
    PASS(identsCount == 0,
         "3.7 quants-only: zero IDENTIFICATIONS_TABLE packets");
    PASS(quantsCount == 1,
         "3.7 quants-only: exactly one QUANTIFICATIONS_TABLE packet");

    NSString *outPath = makeTempPathIQ(@"quants-rt");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    err = nil;
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "3.7 quants-only: writeTtioToPath materialised");

    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(back != nil, "3.7 quants-only: re-opened materialised .tio");
    PASS(back.quantifications.count == 2,
         "3.7 quants-only: quantifications round-tripped (count=2)");
    PASS(back.identifications.count == 0,
         "3.7 quants-only: no identifications materialised");

    if (back.quantifications.count == 2) {
        TTIOQuantification *q0 = back.quantifications[0];
        PASS([q0.chemicalEntity isEqualToString:@"CompoundA"],
             "3.7 quants-only: row0 chemicalEntity");
        PASS([q0.sampleRef isEqualToString:@"sampleA"],
             "3.7 quants-only: row0 sampleRef");
        PASS(q0.abundance == 123.45,
             "3.7 quants-only: row0 abundance");
        PASS([q0.normalizationMethod isEqualToString:@"median"],
             "3.7 quants-only: row0 normalizationMethod");
        PASS([q0.unit isEqualToString:@"ng/mL"],
             "3.7 quants-only: row0 unit");
        TTIOQuantification *q1 = back.quantifications[1];
        PASS([q1.chemicalEntity isEqualToString:@"CompoundB"],
             "3.7 quants-only: row1 chemicalEntity");
        PASS([q1.normalizationMethod isEqualToString:@"TIC"],
             "3.7 quants-only: row1 normalizationMethod");
    }

    [back closeFile];
    unlink([outPath fileSystemRepresentation]);
}

// -------- 3. empty lists emit zero packets ---------------------------------

static void testEmptyListsEmitNoPackets(void)
{
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"iq-empty"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.7 empty: StreamHeader");
    PASS([w writeIdentificationsTable:@[] error:&err],
         "3.7 empty: writeIdentificationsTable: returns YES for empty");
    PASS([w writeQuantificationsTable:@[] error:&err],
         "3.7 empty: writeQuantificationsTable: returns YES for empty");
    PASS([w writeEndOfStreamWithError:&err],
         "3.7 empty: EndOfStream");

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    BOOL sawAny = NO;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType == TTIOTransportPacketIdentificationsTable
         || rec.header.packetType == TTIOTransportPacketQuantificationsTable) {
            sawAny = YES;
            break;
        }
    }
    PASS(!sawAny,
         "3.7 empty: empty lists emit NO 0x16/0x17 packets");
    // StreamHeader + EndOfStream only.
    PASS(records.count == 2,
         "3.7 empty: exactly 2 packets (StreamHeader + EndOfStream)");
}

// -------- 4. both populated -> 0x16 before 0x17 ----------------------------

static void testBothPopulatedIdentificationsBeforeQuantifications(void)
{
    NSArray<TTIOIdentification *> *idents = buildIdentificationsFixture();
    NSArray<TTIOQuantification *> *quants = buildQuantificationsFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"iq-both"
                               isaInvestigation:@""
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "3.7 both: StreamHeader");
    // Per spec §5.4 step 6: identifications first, then quantifications.
    PASS([w writeIdentificationsTable:idents error:&err],
         "3.7 both: writeIdentificationsTable");
    PASS([w writeQuantificationsTable:quants error:&err],
         "3.7 both: writeQuantificationsTable");
    PASS([w writeEndOfStreamWithError:&err],
         "3.7 both: EndOfStream");

    TTIOTransportReader *probe =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [probe readAllPacketsWithError:&err];

    NSInteger identsIdx = -1, quantsIdx = -1;
    int identsCount = 0, quantsCount = 0;
    for (NSUInteger i = 0; i < records.count; i++) {
        TTIOTransportPacketType t = records[i].header.packetType;
        if (t == TTIOTransportPacketIdentificationsTable) {
            if (identsIdx < 0) identsIdx = (NSInteger)i;
            identsCount++;
        } else if (t == TTIOTransportPacketQuantificationsTable) {
            if (quantsIdx < 0) quantsIdx = (NSInteger)i;
            quantsCount++;
        }
    }
    PASS(identsCount == 1,
         "3.7 both: exactly one IDENTIFICATIONS_TABLE packet");
    PASS(quantsCount == 1,
         "3.7 both: exactly one QUANTIFICATIONS_TABLE packet");
    PASS(identsIdx > 0 && quantsIdx > 0,
         "3.7 both: both packets are present in the stream");
    PASS(identsIdx < quantsIdx,
         "3.7 both: per §5.4 step 6, IDENTIFICATIONS_TABLE precedes "
         "QUANTIFICATIONS_TABLE");

    // Round-trip via writeTtioToPath: confirms reader accumulates BOTH.
    NSString *outPath = makeTempPathIQ(@"both-rt");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    err = nil;
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "3.7 both: writeTtioToPath materialised");
    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(back != nil, "3.7 both: re-opened materialised .tio");
    PASS(back.identifications.count == idents.count,
         "3.7 both: identifications count round-trip");
    PASS(back.quantifications.count == quants.count,
         "3.7 both: quantifications count round-trip");
    [back closeFile];
    unlink([outPath fileSystemRepresentation]);
}

// -------- entry point ------------------------------------------------------

void testTransportIdentificationsQuantifications(void);
void testTransportIdentificationsQuantifications(void)
{
    testIdentificationsOnlyRoundTrip();
    testQuantificationsOnlyRoundTrip();
    testEmptyListsEmitNoPackets();
    testBothPopulatedIdentificationsBeforeQuantifications();
    // The writeMinimalDatasetIQ helper is left for Task 3.9 / future
    // tests to use; silence the unused-function warning here.
    (void)writeMinimalDatasetIQ;
}
