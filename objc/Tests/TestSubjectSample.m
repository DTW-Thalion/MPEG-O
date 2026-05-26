/*
 * TestSubjectSample.m — Stage 6 (transport-spec v0.11, Deferral 2)
 *
 * Unit tests for the TTIOSubject + TTIOSample value classes. Validates
 * the spec §4.4 rules:
 *   - external_id / sample_id required, non-empty, no '/'.
 *   - attributes_json byte-form (sort_keys, no whitespace, "{}" empty).
 *
 * Cross-language parity:
 *   Java SpectralDatasetSubjectsSamplesTest (commit dd39f4e6)
 *   Python tests/test_subject.py + test_sample.py (commit 721ad21c)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Dataset/TTIOSubject.h"
#import "Dataset/TTIOSample.h"

// ── TTIOSubject validation + defaults ────────────────────────────────

static void test_subject_minimal(void)
{
    TTIOSubject *s = [[TTIOSubject alloc] initWithExternalId:@"S1"
                                                       project:nil
                                                           sex:nil
                                                     birthYear:0
                                                    attributes:nil];
    PASS([s.externalId isEqualToString:@"S1"],
         "TTIOSubject minimal: externalId set");
    PASS([s.project isEqualToString:@""],
         "TTIOSubject minimal: project defaults to @\"\"");
    PASS([s.sex isEqualToString:@""],
         "TTIOSubject minimal: sex defaults to @\"\"");
    PASS(s.birthYear == 0,
         "TTIOSubject minimal: birthYear defaults to 0");
    PASS(s.attributes.count == 0,
         "TTIOSubject minimal: attributes defaults to @{}");
}

static void test_subject_empty_external_id_raises(void)
{
    BOOL raised = NO;
    @try {
        (void)[[TTIOSubject alloc] initWithExternalId:@""
                                                project:nil
                                                    sex:nil
                                              birthYear:0
                                             attributes:nil];
    } @catch (NSException *exc) {
        raised = ([exc.name isEqualToString:NSInvalidArgumentException]);
    }
    PASS(raised,
         "TTIOSubject empty externalId raises NSInvalidArgumentException");
}

static void test_subject_slash_external_id_raises(void)
{
    BOOL raised = NO;
    @try {
        (void)[[TTIOSubject alloc] initWithExternalId:@"patient/01"
                                                project:nil
                                                    sex:nil
                                              birthYear:0
                                             attributes:nil];
    } @catch (NSException *exc) {
        raised = ([exc.name isEqualToString:NSInvalidArgumentException]);
    }
    PASS(raised,
         "TTIOSubject '/'-containing externalId raises");
}

static void test_subject_attributes_json_empty(void)
{
    TTIOSubject *s = [[TTIOSubject alloc] initWithExternalId:@"S1"
                                                       project:nil
                                                           sex:nil
                                                     birthYear:0
                                                    attributes:nil];
    PASS([[s attributesJson] isEqualToString:@"{}"],
         "TTIOSubject empty attributesJson -> \"{}\"");
}

static void test_subject_attributes_json_sorted_keys(void)
{
    // Cross-lang byte parity: Java/Python both produce
    // {"alpha":"a","mu":"m","zeta":"z"} (sorted, no whitespace).
    TTIOSubject *s = [[TTIOSubject alloc]
        initWithExternalId:@"S1"
                    project:nil
                        sex:nil
                  birthYear:0
                 attributes:@{ @"zeta": @"z",
                                @"alpha": @"a",
                                @"mu":   @"m" }];
    NSString *json = [s attributesJson];
    PASS([json isEqualToString:@"{\"alpha\":\"a\",\"mu\":\"m\",\"zeta\":\"z\"}"],
         "TTIOSubject attributesJson sort_keys + no whitespace");
}

static void test_subject_all_fields_populated(void)
{
    TTIOSubject *s = [[TTIOSubject alloc]
        initWithExternalId:@"S1"
                    project:@"STUDY-A"
                        sex:@"F"
                  birthYear:1985
                 attributes:@{ @"site": @"NYC" }];
    PASS([s.externalId isEqualToString:@"S1"],     "subject all: externalId");
    PASS([s.project    isEqualToString:@"STUDY-A"], "subject all: project");
    PASS([s.sex        isEqualToString:@"F"],       "subject all: sex");
    PASS(s.birthYear == 1985,                       "subject all: birthYear");
    PASS([s.attributes[@"site"] isEqualToString:@"NYC"],
         "subject all: attributes preserved");
}

// ── TTIOSample validation + defaults ─────────────────────────────────

static void test_sample_minimal(void)
{
    TTIOSample *s = [[TTIOSample alloc] initWithSampleId:@"M1"
                                        subjectExternalId:nil
                                               sampleKind:nil
                                              collectedAt:0
                                               attributes:nil];
    PASS([s.sampleId isEqualToString:@"M1"],
         "TTIOSample minimal: sampleId set");
    PASS([s.subjectExternalId isEqualToString:@""],
         "TTIOSample minimal: subjectExternalId defaults to @\"\"");
    PASS([s.sampleKind isEqualToString:@""],
         "TTIOSample minimal: sampleKind defaults to @\"\"");
    PASS(s.collectedAt == 0,
         "TTIOSample minimal: collectedAt defaults to 0");
    PASS(s.attributes.count == 0,
         "TTIOSample minimal: attributes defaults to @{}");
}

static void test_sample_empty_sample_id_raises(void)
{
    BOOL raised = NO;
    @try {
        (void)[[TTIOSample alloc] initWithSampleId:@""
                                  subjectExternalId:nil
                                         sampleKind:nil
                                        collectedAt:0
                                         attributes:nil];
    } @catch (NSException *exc) {
        raised = ([exc.name isEqualToString:NSInvalidArgumentException]);
    }
    PASS(raised, "TTIOSample empty sampleId raises");
}

static void test_sample_slash_sample_id_raises(void)
{
    BOOL raised = NO;
    @try {
        (void)[[TTIOSample alloc] initWithSampleId:@"plate/1"
                                  subjectExternalId:nil
                                         sampleKind:nil
                                        collectedAt:0
                                         attributes:nil];
    } @catch (NSException *exc) {
        raised = ([exc.name isEqualToString:NSInvalidArgumentException]);
    }
    PASS(raised, "TTIOSample '/'-containing sampleId raises");
}

static void test_sample_attributes_json_empty(void)
{
    TTIOSample *s = [[TTIOSample alloc] initWithSampleId:@"M1"
                                        subjectExternalId:nil
                                               sampleKind:nil
                                              collectedAt:0
                                               attributes:nil];
    PASS([[s attributesJson] isEqualToString:@"{}"],
         "TTIOSample empty attributesJson -> \"{}\"");
}

static void test_sample_attributes_json_sorted_keys(void)
{
    TTIOSample *s = [[TTIOSample alloc]
        initWithSampleId:@"M1"
       subjectExternalId:nil
              sampleKind:nil
             collectedAt:0
              attributes:@{ @"site": @"NYC",
                             @"cohort": @"A1",
                             @"race": @"white" }];
    NSString *json = [s attributesJson];
    PASS([json isEqualToString:
            @"{\"cohort\":\"A1\",\"race\":\"white\",\"site\":\"NYC\"}"],
         "TTIOSample attributesJson sort_keys + no whitespace");
}

static void test_sample_all_fields_populated(void)
{
    TTIOSample *s = [[TTIOSample alloc]
        initWithSampleId:@"M1"
       subjectExternalId:@"S1"
              sampleKind:@"plasma"
             collectedAt:1716671000
              attributes:@{ @"freezer": @"L-80" }];
    PASS([s.sampleId          isEqualToString:@"M1"],     "sample all: sampleId");
    PASS([s.subjectExternalId isEqualToString:@"S1"],     "sample all: subjectExternalId");
    PASS([s.sampleKind        isEqualToString:@"plasma"], "sample all: sampleKind");
    PASS(s.collectedAt == 1716671000,                      "sample all: collectedAt");
    PASS([s.attributes[@"freezer"] isEqualToString:@"L-80"],
         "sample all: attributes preserved");
}

void testSubjectSample(void)
{
    test_subject_minimal();
    test_subject_empty_external_id_raises();
    test_subject_slash_external_id_raises();
    test_subject_attributes_json_empty();
    test_subject_attributes_json_sorted_keys();
    test_subject_all_fields_populated();

    test_sample_minimal();
    test_sample_empty_sample_id_raises();
    test_sample_slash_sample_id_raises();
    test_sample_attributes_json_empty();
    test_sample_attributes_json_sorted_keys();
    test_sample_all_fields_populated();
}
