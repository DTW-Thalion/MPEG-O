/*
 * TestSpectralDatasetSubjectsSamples.m — Stage 6 (transport-spec
 * v0.11, Deferral 2). Round-trip TTIOSubject + TTIOSample through the
 * /study/subjects/<external_id>/ + /study/samples/<sample_id>/ HDF5
 * group layout.
 *
 * The writer side is exercised by writing the per-row groups
 * directly via TTIOHDF5Group primitives, mirroring how the transport
 * reader (Commit 3) will layer them onto the freshly-materialised
 * .tio after +writeMinimalToPath: returns. The reader side is the
 * lazy -subjects / -samples accessors on TTIOSpectralDataset.
 *
 * Cross-language parity:
 *   Java SpectralDatasetSubjectsSamplesTest (commit dd39f4e6)
 *   Python tests/test_spectral_dataset_subjects_samples.py
 *     (commit 721ad21c)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSubject.h"
#import "Dataset/TTIOSample.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#include <unistd.h>

// ── helpers ──────────────────────────────────────────────────────────

static NSString *makeTempPath_SS(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_ss_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:base];
}

// Build an empty .tio at `path` then layer in the given subjects +
// samples as per-row HDF5 groups under /study/subjects/ + /study/samples/.
// Mirrors the exact write pattern the transport reader uses in
// -writeTtioToPath: after +writeMinimalToPath: returns.
static BOOL buildFixtureAtPath(NSString *path,
                               NSArray<TTIOSubject *> *subjects,
                               NSArray<TTIOSample *> *samples,
                               NSError **error)
{
    unlink([path fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"ss-fixture"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:error];
    if (!ok) return NO;
    if (subjects.count == 0 && samples.count == 0) return YES;

    // Reopen RW and inject /study/subjects + /study/samples.
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:error];
    if (f == nil) return NO;
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (study == nil) { [f close]; return NO; }

    if (subjects.count > 0) {
        TTIOHDF5Group *sg = [study createGroupNamed:@"subjects" error:error];
        if (sg == nil) { [f close]; return NO; }
        for (TTIOSubject *s in subjects) {
            TTIOHDF5Group *row = [sg createGroupNamed:s.externalId error:error];
            if (row == nil) { [f close]; return NO; }
            if (![row setStringAttribute:@"external_id"
                                    value:s.externalId
                                    error:error]) { [f close]; return NO; }
            if (s.project.length > 0) {
                if (![row setStringAttribute:@"project" value:s.project
                                        error:error]) { [f close]; return NO; }
            }
            if (s.sex.length > 0) {
                if (![row setStringAttribute:@"sex" value:s.sex
                                        error:error]) { [f close]; return NO; }
            }
            if (![row setIntegerAttribute:@"birth_year"
                                      value:s.birthYear
                                      error:error]) { [f close]; return NO; }
            if (![row setStringAttribute:@"attributes_json"
                                    value:[s attributesJson]
                                    error:error]) { [f close]; return NO; }
        }
    }
    if (samples.count > 0) {
        TTIOHDF5Group *smg = [study createGroupNamed:@"samples" error:error];
        if (smg == nil) { [f close]; return NO; }
        for (TTIOSample *s in samples) {
            TTIOHDF5Group *row = [smg createGroupNamed:s.sampleId error:error];
            if (row == nil) { [f close]; return NO; }
            if (![row setStringAttribute:@"sample_id"
                                    value:s.sampleId
                                    error:error]) { [f close]; return NO; }
            if (s.subjectExternalId.length > 0) {
                if (![row setStringAttribute:@"subject_external_id"
                                        value:s.subjectExternalId
                                        error:error]) { [f close]; return NO; }
            }
            if (s.sampleKind.length > 0) {
                if (![row setStringAttribute:@"sample_kind"
                                        value:s.sampleKind
                                        error:error]) { [f close]; return NO; }
            }
            if (![row setIntegerAttribute:@"collected_at"
                                      value:s.collectedAt
                                      error:error]) { [f close]; return NO; }
            if (![row setStringAttribute:@"attributes_json"
                                    value:[s attributesJson]
                                    error:error]) { [f close]; return NO; }
        }
    }
    return [f close];
}

// ── 1. empty round-trip ──────────────────────────────────────────────

static void testEmptyRoundTrip(void)
{
    NSString *path = makeTempPath_SS(@"empty");
    NSError *err = nil;
    PASS(buildFixtureAtPath(path, @[], @[], &err) && err == nil,
         "SS empty: fixture built");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "SS empty: dataset re-opened");
    PASS(ds.subjects.count == 0, "SS empty: subjects accessor returns @[]");
    PASS(ds.samples.count  == 0, "SS empty: samples accessor returns @[]");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

// ── 2. subjects-only round-trip ──────────────────────────────────────

static void testSubjectsOnlyRoundTrip(void)
{
    TTIOSubject *s1 = [[TTIOSubject alloc]
        initWithExternalId:@"S1"
                    project:@"STUDY-A"
                        sex:@"F"
                  birthYear:1985
                 attributes:@{ @"site": @"NYC" }];
    TTIOSubject *s2 = [[TTIOSubject alloc]
        initWithExternalId:@"S2"
                    project:nil
                        sex:nil
                  birthYear:0
                 attributes:nil];
    NSString *path = makeTempPath_SS(@"subjects");
    NSError *err = nil;
    PASS(buildFixtureAtPath(path, @[s1, s2], @[], &err) && err == nil,
         "SS subjects-only: fixture built");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "SS subjects-only: dataset re-opened");
    NSArray<TTIOSubject *> *back = ds.subjects;
    PASS(back.count == 2, "SS subjects-only: 2 subjects round-tripped");
    PASS(ds.samples.count == 0, "SS subjects-only: no samples surfaced");

    // Find S1 + S2 — childNames order isn't lexicographic-guaranteed
    // by HDF5, but in practice we get sorted output.
    TTIOSubject *r1 = nil, *r2 = nil;
    for (TTIOSubject *s in back) {
        if ([s.externalId isEqualToString:@"S1"]) r1 = s;
        if ([s.externalId isEqualToString:@"S2"]) r2 = s;
    }
    PASS(r1 != nil, "SS subjects-only: S1 present");
    PASS(r2 != nil, "SS subjects-only: S2 present");
    if (r1 != nil) {
        PASS([r1.project isEqualToString:@"STUDY-A"],
             "SS subjects-only: S1.project");
        PASS([r1.sex isEqualToString:@"F"], "SS subjects-only: S1.sex");
        PASS(r1.birthYear == 1985,           "SS subjects-only: S1.birthYear");
        PASS([r1.attributes[@"site"] isEqualToString:@"NYC"],
             "SS subjects-only: S1.attributes.site");
    }
    if (r2 != nil) {
        PASS([r2.project isEqualToString:@""],
             "SS subjects-only: S2 minimal project=@\"\"");
        PASS(r2.birthYear == 0,
             "SS subjects-only: S2 minimal birthYear=0");
        PASS(r2.attributes.count == 0,
             "SS subjects-only: S2 minimal attributes=@{}");
    }

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

// ── 3. samples-only round-trip ───────────────────────────────────────

static void testSamplesOnlyRoundTrip(void)
{
    TTIOSample *m1 = [[TTIOSample alloc]
        initWithSampleId:@"M1"
       subjectExternalId:@"S1"
              sampleKind:@"plasma"
             collectedAt:1716671000
              attributes:@{ @"freezer": @"L-80" }];
    TTIOSample *m2 = [[TTIOSample alloc]
        initWithSampleId:@"M2"
       subjectExternalId:nil
              sampleKind:nil
             collectedAt:0
              attributes:nil];
    NSString *path = makeTempPath_SS(@"samples");
    NSError *err = nil;
    PASS(buildFixtureAtPath(path, @[], @[m1, m2], &err) && err == nil,
         "SS samples-only: fixture built");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "SS samples-only: dataset re-opened");
    PASS(ds.subjects.count == 0, "SS samples-only: no subjects surfaced");
    NSArray<TTIOSample *> *back = ds.samples;
    PASS(back.count == 2, "SS samples-only: 2 samples round-tripped");

    TTIOSample *r1 = nil, *r2 = nil;
    for (TTIOSample *s in back) {
        if ([s.sampleId isEqualToString:@"M1"]) r1 = s;
        if ([s.sampleId isEqualToString:@"M2"]) r2 = s;
    }
    PASS(r1 != nil, "SS samples-only: M1 present");
    PASS(r2 != nil, "SS samples-only: M2 present");
    if (r1 != nil) {
        PASS([r1.subjectExternalId isEqualToString:@"S1"],
             "SS samples-only: M1.subjectExternalId");
        PASS([r1.sampleKind isEqualToString:@"plasma"],
             "SS samples-only: M1.sampleKind");
        PASS(r1.collectedAt == 1716671000,
             "SS samples-only: M1.collectedAt");
        PASS([r1.attributes[@"freezer"] isEqualToString:@"L-80"],
             "SS samples-only: M1.attributes.freezer");
    }
    if (r2 != nil) {
        PASS([r2.subjectExternalId isEqualToString:@""],
             "SS samples-only: M2 minimal subjectExternalId=@\"\"");
        PASS(r2.collectedAt == 0,
             "SS samples-only: M2 minimal collectedAt=0");
        PASS(r2.attributes.count == 0,
             "SS samples-only: M2 minimal attributes=@{}");
    }

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

// ── 4. validation: duplicate IDs raise ───────────────────────────────

static void testValidationDuplicatesRaise(void)
{
    TTIOSubject *s1a = [[TTIOSubject alloc] initWithExternalId:@"X"
                                                          project:nil
                                                              sex:nil
                                                        birthYear:0
                                                       attributes:nil];
    TTIOSubject *s1b = [[TTIOSubject alloc] initWithExternalId:@"X"
                                                          project:@"other"
                                                              sex:nil
                                                        birthYear:0
                                                       attributes:nil];
    BOOL raised = NO;
    @try {
        [TTIOSpectralDataset validateSubjects:@[s1a, s1b] samples:@[]];
    } @catch (NSException *exc) {
        raised = [exc.reason rangeOfString:@"duplicate"].location != NSNotFound;
    }
    PASS(raised, "SS validate: duplicate Subject.externalId raises");

    TTIOSample *m1 = [[TTIOSample alloc] initWithSampleId:@"M"
                                          subjectExternalId:nil
                                                 sampleKind:nil
                                                collectedAt:0
                                                 attributes:nil];
    TTIOSample *m1b = [[TTIOSample alloc] initWithSampleId:@"M"
                                          subjectExternalId:nil
                                                 sampleKind:@"tissue"
                                                collectedAt:0
                                                 attributes:nil];
    raised = NO;
    @try {
        [TTIOSpectralDataset validateSubjects:@[] samples:@[m1, m1b]];
    } @catch (NSException *exc) {
        raised = [exc.reason rangeOfString:@"duplicate"].location != NSNotFound;
    }
    PASS(raised, "SS validate: duplicate Sample.sampleId raises");
}

// ── 5. soft-FK warning via NSLog capture ─────────────────────────────

// Capture NSLog output by reopening stderr (NSLog goes to fd 2).
static NSString *captureNSLogDuring(void (^block)(void))
{
    int saved = dup(STDERR_FILENO);
    char tmpl[] = "/tmp/ttio_ss_log_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return @"";
    if (dup2(fd, STDERR_FILENO) < 0) {
        close(fd);
        return @"";
    }
    block();
    fflush(stderr);
    dup2(saved, STDERR_FILENO);
    close(saved);
    close(fd);
    NSString *content =
        [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:tmpl]
                                  encoding:NSUTF8StringEncoding error:NULL]
        ?: @"";
    unlink(tmpl);
    return content;
}

static void testSoftFkWarning(void)
{
    TTIOSubject *s1 = [[TTIOSubject alloc] initWithExternalId:@"S1"
                                                         project:nil
                                                             sex:nil
                                                       birthYear:0
                                                      attributes:nil];
    // M1 references S99 which doesn't exist in the subjects list.
    TTIOSample *m1 = [[TTIOSample alloc] initWithSampleId:@"M1"
                                         subjectExternalId:@"S99"
                                                sampleKind:nil
                                               collectedAt:0
                                                attributes:nil];
    BOOL raised = NO;
    NSString *captured = captureNSLogDuring(^{
        @try {
            [TTIOSpectralDataset validateSubjects:@[s1] samples:@[m1]];
        } @catch (NSException *exc) {
            (void)exc;
            // soft-FK should NOT raise — it's a warning.
        }
    });
    (void)raised;
    PASS([captured rangeOfString:@"WARNING"].location != NSNotFound,
         "SS soft-FK: NSLog WARNING emitted on FK mismatch");
    PASS([captured rangeOfString:@"S99"].location != NSNotFound,
         "SS soft-FK: warning mentions missing subject id");
    PASS([captured rangeOfString:@"M1"].location != NSNotFound,
         "SS soft-FK: warning mentions sample id");
}

// ── 6. attributes_json byte form on disk ─────────────────────────────

static void testAttributesJsonOnDiskByteForm(void)
{
    TTIOSubject *s = [[TTIOSubject alloc]
        initWithExternalId:@"S1"
                    project:nil
                        sex:nil
                  birthYear:0
                 attributes:@{ @"zeta": @"z",
                                @"alpha": @"a",
                                @"mu":   @"m" }];
    NSString *path = makeTempPath_SS(@"attrsjson");
    NSError *err = nil;
    PASS(buildFixtureAtPath(path, @[s], @[], &err) && err == nil,
         "SS attrsjson: fixture built");

    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:&err];
    PASS(f != nil, "SS attrsjson: reopen for raw inspection");
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:&err];
    TTIOHDF5Group *subjects = [study openGroupNamed:@"subjects" error:&err];
    TTIOHDF5Group *row = [subjects openGroupNamed:@"S1" error:&err];
    NSString *json = [row stringAttributeNamed:@"attributes_json" error:&err];
    PASS([json isEqualToString:
            @"{\"alpha\":\"a\",\"mu\":\"m\",\"zeta\":\"z\"}"],
         "SS attrsjson: on-disk byte-form matches Java/Python "
         "(sort_keys + no whitespace)");
    [f close];
    unlink([path fileSystemRepresentation]);
}

void testSpectralDatasetSubjectsSamples(void)
{
    testEmptyRoundTrip();
    testSubjectsOnlyRoundTrip();
    testSamplesOnlyRoundTrip();
    testValidationDuplicatesRaise();
    testSoftFkWarning();
    testAttributesJsonOnDiskByteForm();
}
