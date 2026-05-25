/*
 * TestArrowIpcCodec — TTIOArrowIpcCodec round-trip tests.
 *
 * Transport-spec v0.11 tabular packet payloads:
 *   - IDENTIFICATIONS_TABLE (0x16)
 *   - QUANTIFICATIONS_TABLE (0x17)
 *
 * Cross-language parity: payloads are LOGICALLY equivalent to Java's
 * global.thalion.ttio.transport.ArrowIpcCodec and Python's
 * ttio.transport.arrow_ipc but NOT byte-identical -- Arrow IPC
 * flatbuffer framing differs slightly between language SDKs. Each
 * SDK must round-trip its own bytes (this test) and accept the other
 * SDKs' bytes (covered by the cross-language conformance suite, not
 * here).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOArrowIpcCodec.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"

static void test_identifications_round_trip(void)
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
          evidenceChain:@[]]; // empty evidence chain

    NSData *ipc = [TTIOArrowIpcCodec encodeIdentifications:@[r1, r2, r3]];
    PASS(ipc != nil && ipc.length > 0,
         "encodeIdentifications returns non-empty bytes");

    NSArray<TTIOIdentification *> *out =
        [TTIOArrowIpcCodec decodeIdentifications:ipc];
    PASS(out.count == 3, "decodeIdentifications returns 3 rows");

    PASS([out[0].runName isEqualToString:@"run1"],          "row0 run_name");
    PASS(out[0].spectrumIndex == 42,                        "row0 spectrum_index");
    PASS([out[0].chemicalEntity isEqualToString:@"CompoundA"], "row0 chemical_entity");
    PASS(out[0].confidenceScore == 0.91,                    "row0 confidence_score");
    PASS([out[0].evidenceChain isEqualToArray:(@[@"e1", @"e2"])],
         "row0 evidence_chain round-trip");

    PASS([out[1].chemicalEntity isEqualToString:@"CompoundB"], "row1 chemical_entity");
    PASS([out[1].evidenceChain isEqualToArray:@[@"e3"]],    "row1 evidence_chain");

    PASS([out[2].runName isEqualToString:@"run2"],          "row2 run_name");
    PASS(out[2].spectrumIndex == 0,                         "row2 spectrum_index");
    PASS(out[2].evidenceChain.count == 0,                   "row2 empty evidence_chain");
}

static void test_quantifications_round_trip(void)
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
                     abundance:0.0
           normalizationMethod:@""
                          unit:@""];
    TTIOQuantification *q3 = [[TTIOQuantification alloc]
        initWithChemicalEntity:@"CompoundC"
                     sampleRef:@"sampleC"
                     abundance:-1.5e6
           normalizationMethod:@"TIC"
                          unit:@"peak-area"];

    NSData *ipc = [TTIOArrowIpcCodec encodeQuantifications:@[q1, q2, q3]];
    PASS(ipc != nil && ipc.length > 0,
         "encodeQuantifications returns non-empty bytes");

    NSArray<TTIOQuantification *> *out =
        [TTIOArrowIpcCodec decodeQuantifications:ipc];
    PASS(out.count == 3, "decodeQuantifications returns 3 rows");

    PASS([out[0].chemicalEntity isEqualToString:@"CompoundA"], "row0 chemical_entity");
    PASS([out[0].sampleRef isEqualToString:@"sampleA"],     "row0 sample_ref");
    PASS(out[0].abundance == 123.45,                        "row0 abundance");
    PASS([out[0].normalizationMethod isEqualToString:@"median"],
         "row0 normalization_method");
    PASS([out[0].unit isEqualToString:@"ng/mL"],            "row0 unit");

    PASS(out[1].abundance == 0.0,                           "row1 abundance zero");
    PASS([out[1].unit isEqualToString:@""],                 "row1 unit empty");

    PASS(out[2].abundance == -1.5e6,                        "row2 abundance large negative");
    PASS([out[2].normalizationMethod isEqualToString:@"TIC"],
         "row2 normalization_method");
    PASS([out[2].unit isEqualToString:@"peak-area"],        "row2 unit");
}

static void test_empty_lists_round_trip(void)
{
    NSData *idIpc = [TTIOArrowIpcCodec encodeIdentifications:@[]];
    PASS(idIpc != nil, "empty identifications encode -> non-nil");

    NSArray *idOut = [TTIOArrowIpcCodec decodeIdentifications:idIpc];
    PASS(idOut != nil && idOut.count == 0,
         "empty identifications IPC round-trips to empty array");

    NSData *qIpc = [TTIOArrowIpcCodec encodeQuantifications:@[]];
    PASS(qIpc != nil, "empty quantifications encode -> non-nil");

    NSArray *qOut = [TTIOArrowIpcCodec decodeQuantifications:qIpc];
    PASS(qOut != nil && qOut.count == 0,
         "empty quantifications IPC round-trips to empty array");

    /* nil + zero-length bytes -> empty array. */
    PASS([TTIOArrowIpcCodec decodeIdentifications:nil].count == 0,
         "decodeIdentifications(nil) -> @[]");
    PASS([TTIOArrowIpcCodec decodeQuantifications:[NSData data]].count == 0,
         "decodeQuantifications(empty NSData) -> @[]");
}

void testArrowIpcCodec(void)
{
    test_identifications_round_trip();
    test_quantifications_round_trip();
    test_empty_lists_round_trip();
}
