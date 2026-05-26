/*
 * TestArrowIpcCodecSubjectsSamples.m — Stage 6 (transport-spec v0.11,
 * Deferral 2). Round-trip TTIOSubject + TTIOSample through the Arrow
 * IPC codec (packets 0x19 / 0x1A).
 *
 * Null convention (cross-lang with Java + Python):
 *   - Optional strings (project, sex, subject_external_id, sample_kind):
 *     empty @"" -> Arrow null -> @"" on read.
 *   - Optional ints (birth_year, collected_at):
 *     sentinel 0 -> Arrow null -> 0 on read.
 *   - attributes_json: always present ("{}" for empty maps).
 *
 * Cross-language parity:
 *   Java ArrowIpcCodecSubjectsSamplesTest (commit dd211600)
 *   Python tests/test_arrow_ipc_subjects_samples.py (commit a8f6eb03)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOArrowIpcCodec.h"
#import "Dataset/TTIOSubject.h"
#import "Dataset/TTIOSample.h"

// ── 1. subjects empty round-trip ─────────────────────────────────────

static void test_subjects_empty(void)
{
    NSData *ipc = [TTIOArrowIpcCodec encodeSubjects:@[]];
    PASS(ipc != nil && ipc.length > 0,
         "subjects empty encode -> non-empty IPC bytes");
    NSArray<TTIOSubject *> *out = [TTIOArrowIpcCodec decodeSubjects:ipc];
    PASS(out != nil && out.count == 0,
         "subjects empty round-trips to @[]");

    PASS([TTIOArrowIpcCodec decodeSubjects:nil].count == 0,
         "decodeSubjects(nil) -> @[]");
    PASS([TTIOArrowIpcCodec decodeSubjects:[NSData data]].count == 0,
         "decodeSubjects(empty NSData) -> @[]");
}

// ── 2. subjects non-empty + sentinel round-trip ──────────────────────

static void test_subjects_round_trip(void)
{
    TTIOSubject *s1 = [[TTIOSubject alloc]
        initWithExternalId:@"S1"
                    project:@"STUDY-A"
                        sex:@"F"
                  birthYear:1985
                 attributes:@{ @"site": @"NYC" }];
    // S2 exercises all the sentinel/empty mappings.
    TTIOSubject *s2 = [[TTIOSubject alloc]
        initWithExternalId:@"S2"
                    project:nil
                        sex:nil
                  birthYear:0
                 attributes:nil];
    NSData *ipc = [TTIOArrowIpcCodec encodeSubjects:@[s1, s2]];
    PASS(ipc != nil && ipc.length > 0,
         "subjects round-trip: encode produced bytes");
    NSArray<TTIOSubject *> *out = [TTIOArrowIpcCodec decodeSubjects:ipc];
    PASS(out.count == 2, "subjects round-trip: 2 rows back");

    PASS([out[0].externalId isEqualToString:@"S1"],
         "subjects row0 externalId");
    PASS([out[0].project    isEqualToString:@"STUDY-A"],
         "subjects row0 project");
    PASS([out[0].sex        isEqualToString:@"F"],
         "subjects row0 sex");
    PASS(out[0].birthYear == 1985,
         "subjects row0 birthYear");
    PASS([out[0].attributes[@"site"] isEqualToString:@"NYC"],
         "subjects row0 attributes.site");

    // Row 1: empty strings should have ridden the wire as Arrow null
    // and come back as @"" — and birthYear 0 should round-trip as 0.
    PASS([out[1].externalId isEqualToString:@"S2"],
         "subjects row1 externalId");
    PASS([out[1].project    isEqualToString:@""],
         "subjects row1 project: Arrow null -> @\"\"");
    PASS([out[1].sex        isEqualToString:@""],
         "subjects row1 sex: Arrow null -> @\"\"");
    PASS(out[1].birthYear == 0,
         "subjects row1 birthYear: sentinel 0 round-trips");
    PASS(out[1].attributes.count == 0,
         "subjects row1 attributes empty (\"{}\")");
}

// ── 3. samples empty round-trip ──────────────────────────────────────

static void test_samples_empty(void)
{
    NSData *ipc = [TTIOArrowIpcCodec encodeSamples:@[]];
    PASS(ipc != nil && ipc.length > 0,
         "samples empty encode -> non-empty IPC bytes");
    NSArray<TTIOSample *> *out = [TTIOArrowIpcCodec decodeSamples:ipc];
    PASS(out != nil && out.count == 0,
         "samples empty round-trips to @[]");

    PASS([TTIOArrowIpcCodec decodeSamples:nil].count == 0,
         "decodeSamples(nil) -> @[]");
}

// ── 4. samples non-empty + sentinel round-trip ───────────────────────

static void test_samples_round_trip(void)
{
    TTIOSample *m1 = [[TTIOSample alloc]
        initWithSampleId:@"M1"
       subjectExternalId:@"S1"
              sampleKind:@"plasma"
             collectedAt:1716671000
              attributes:@{ @"freezer": @"L-80" }];
    // M2 = anonymous sample with no FK and no collected_at.
    TTIOSample *m2 = [[TTIOSample alloc]
        initWithSampleId:@"M2"
       subjectExternalId:nil
              sampleKind:nil
             collectedAt:0
              attributes:nil];
    NSData *ipc = [TTIOArrowIpcCodec encodeSamples:@[m1, m2]];
    PASS(ipc != nil && ipc.length > 0,
         "samples round-trip: encode produced bytes");
    NSArray<TTIOSample *> *out = [TTIOArrowIpcCodec decodeSamples:ipc];
    PASS(out.count == 2, "samples round-trip: 2 rows back");

    PASS([out[0].sampleId          isEqualToString:@"M1"],
         "samples row0 sampleId");
    PASS([out[0].subjectExternalId isEqualToString:@"S1"],
         "samples row0 subjectExternalId");
    PASS([out[0].sampleKind        isEqualToString:@"plasma"],
         "samples row0 sampleKind");
    PASS(out[0].collectedAt == 1716671000,
         "samples row0 collectedAt");
    PASS([out[0].attributes[@"freezer"] isEqualToString:@"L-80"],
         "samples row0 attributes.freezer");

    PASS([out[1].sampleId          isEqualToString:@"M2"],
         "samples row1 sampleId");
    PASS([out[1].subjectExternalId isEqualToString:@""],
         "samples row1 subjectExternalId: Arrow null -> @\"\"");
    PASS([out[1].sampleKind        isEqualToString:@""],
         "samples row1 sampleKind: Arrow null -> @\"\"");
    PASS(out[1].collectedAt == 0,
         "samples row1 collectedAt: sentinel 0 round-trips");
    PASS(out[1].attributes.count == 0,
         "samples row1 attributes empty");
}

// ── 5. attributes_json multi-key sort_keys byte form ─────────────────

static void test_attributes_json_multi_key(void)
{
    // Verify that what TTIOSubject.attributesJson emits matches Java
    // and Python byte-for-byte. The IPC payload bytes themselves are
    // not byte-equal across SDKs (different flatbuffer envelope), but
    // the attributes_json column value is.
    TTIOSubject *s = [[TTIOSubject alloc]
        initWithExternalId:@"S1"
                    project:nil
                        sex:nil
                  birthYear:0
                 attributes:@{ @"zeta": @"z",
                                @"alpha": @"a",
                                @"mu":   @"m" }];
    NSData *ipc = [TTIOArrowIpcCodec encodeSubjects:@[s]];
    NSArray<TTIOSubject *> *out = [TTIOArrowIpcCodec decodeSubjects:ipc];
    PASS(out.count == 1, "attrs_json mk: round-trip");
    // The decoded TTIOSubject re-emits the JSON the same way.
    PASS([[out[0] attributesJson]
            isEqualToString:@"{\"alpha\":\"a\",\"mu\":\"m\",\"zeta\":\"z\"}"],
         "attrs_json mk: decoded subject re-emits sort_keys byte-form");
    PASS([out[0].attributes[@"zeta"] isEqualToString:@"z"]
         && [out[0].attributes[@"alpha"] isEqualToString:@"a"]
         && [out[0].attributes[@"mu"]   isEqualToString:@"m"],
         "attrs_json mk: all 3 keys decoded");
}

// ── 6. attributes_json never-null contract ───────────────────────────

static void test_attributes_json_never_null(void)
{
    // Every row carries attributes_json on the wire even when the
    // dataclass attributes are empty. Verify the decoded subject's
    // attributes_json comes back as the literal "{}", not "" or null.
    TTIOSubject *s = [[TTIOSubject alloc] initWithExternalId:@"S1"
                                                       project:nil
                                                           sex:nil
                                                     birthYear:0
                                                    attributes:nil];
    NSData *ipc = [TTIOArrowIpcCodec encodeSubjects:@[s]];
    NSArray<TTIOSubject *> *out = [TTIOArrowIpcCodec decodeSubjects:ipc];
    PASS([[out[0] attributesJson] isEqualToString:@"{}"],
         "attrs_json: empty map encodes as \"{}\" and round-trips identically");

    TTIOSample *m = [[TTIOSample alloc] initWithSampleId:@"M1"
                                        subjectExternalId:nil
                                               sampleKind:nil
                                              collectedAt:0
                                               attributes:nil];
    NSData *ipc2 = [TTIOArrowIpcCodec encodeSamples:@[m]];
    NSArray<TTIOSample *> *out2 = [TTIOArrowIpcCodec decodeSamples:ipc2];
    PASS([[out2[0] attributesJson] isEqualToString:@"{}"],
         "attrs_json: Sample empty map -> \"{}\" round-trip");
}

void testArrowIpcCodecSubjectsSamples(void)
{
    test_subjects_empty();
    test_subjects_round_trip();
    test_samples_empty();
    test_samples_round_trip();
    test_attributes_json_multi_key();
    test_attributes_json_never_null();
}
