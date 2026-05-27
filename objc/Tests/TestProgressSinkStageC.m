/*
 * TestProgressSinkStageC.m
 * TTI-O Objective-C tests
 *
 * Stage C (spectroscopic) reader progress hooks: mzML, nmrML,
 * JCAMP-DX, imzML, mzTab. Mirrors Java's Stage C reader tests
 * (PR #175) and Python's PR #179 commit e95ebc28.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOProgressSink.h"
#import "Import/TTIOMzMLReader.h"
#import "Import/TTIONmrMLReader.h"
#import "Import/TTIOJcampDxReader.h"
#import "Import/TTIOMzTabReader.h"
#import "Import/TTIOImzMLReader.h"
#import "Spectra/TTIOSpectrum.h"

// --- locate fixtures ----------------------------------------------------

static NSString *psStageCFixturePath(NSString *leaf)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *candidates = @[
        [@"Fixtures" stringByAppendingPathComponent:leaf],
        [@"../Fixtures" stringByAppendingPathComponent:leaf],
        [@"Tests/Fixtures" stringByAppendingPathComponent:leaf],
        [@"../Tests/Fixtures" stringByAppendingPathComponent:leaf],
    ];
    for (NSString *p in candidates) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    // Return the first candidate to give a useful error message.
    return candidates[0];
}

// --- mzML ---------------------------------------------------------------

static void testMzMLProgress(void)
{
    NSString *path = psStageCFixturePath(@"1min.mzML");
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"SKIP testMzMLProgress: 1min.mzML fixture missing");
        return;
    }
    NSError *err = nil;
    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };

    TTIOSpectralDataset *ds = [TTIOMzMLReader readFromFilePath:path
                                                       progress:cb
                                                          error:&err];
    PASS(ds != nil, "mzML parses with progress");
    PASS(doneVals.count >= 1, "at least one mzML progress fire (final)");
    if (doneVals.count >= 1) {
        PASS([[doneVals lastObject] longLongValue] ==
             [[totalVals lastObject] longLongValue],
             "mzML final fire stamps done == total");
    }
    // Legacy overload still works.
    NSError *err2 = nil;
    TTIOSpectralDataset *ds2 = [TTIOMzMLReader readFromFilePath:path error:&err2];
    PASS(ds2 != nil, "legacy mzML overload (no progress) still parses");
}

// --- nmrML --------------------------------------------------------------

static void testNmrMLProgress(void)
{
    NSString *path = psStageCFixturePath(@"bmse000325.nmrML");
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"SKIP testNmrMLProgress: bmse000325.nmrML fixture missing");
        return;
    }
    NSError *err = nil;
    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };

    TTIOSpectralDataset *ds = [TTIONmrMLReader readFromFilePath:path
                                                        progress:cb
                                                           error:&err];
    PASS(ds != nil, "nmrML parses with progress");
    // nmrML is single-spectrum: exactly one (1, 1) fire.
    PASS(doneVals.count == 1, "nmrML fires exactly once");
    if (doneVals.count == 1) {
        PASS([doneVals[0] longLongValue] == 1 &&
             [totalVals[0] longLongValue] == 1,
             "nmrML fire is (1, 1)");
    }
    // Legacy overload still works.
    NSError *err2 = nil;
    TTIOSpectralDataset *ds2 = [TTIONmrMLReader readFromFilePath:path error:&err2];
    PASS(ds2 != nil, "legacy nmrML overload (no progress) still parses");
}

// --- JCAMP-DX -----------------------------------------------------------

static void testJcampDxProgress(void)
{
    NSString *tmp = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    // Minimal JCAMP-DX RAMAN file. Mirrors the synthetic fixture
    // already used elsewhere in the test suite.
    NSString *jcamp =
        @"##TITLE= test\n"
        @"##JCAMP-DX= 5.01\n"
        @"##DATA TYPE= RAMAN SPECTRUM\n"
        @"##ORIGIN= test\n"
        @"##OWNER= test\n"
        @"##XUNITS= 1/CM\n"
        @"##YUNITS= COUNTS\n"
        @"##XFACTOR= 1\n"
        @"##YFACTOR= 1\n"
        @"##FIRSTX= 100.0\n"
        @"##LASTX= 102.0\n"
        @"##NPOINTS= 3\n"
        @"##XYDATA= (X++(Y..Y))\n"
        @"100.0 10.0\n"
        @"101.0 20.0\n"
        @"102.0 30.0\n"
        @"##END=\n";
    NSString *path = [tmp stringByAppendingPathComponent:@"raman.jdx"];
    [jcamp writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSError *err = nil;
    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    TTIOSpectrum *spec = [TTIOJcampDxReader readSpectrumFromPath:path
                                                         progress:cb
                                                            error:&err];
    PASS(spec != nil, "JCAMP-DX Raman parses with progress");
    PASS(doneVals.count == 1, "JCAMP-DX fires exactly once");
    if (doneVals.count == 1) {
        PASS([doneVals[0] longLongValue] == 1 &&
             [totalVals[0] longLongValue] == 1,
             "JCAMP-DX fire is (1, 1)");
    }
    // Legacy overload still works.
    NSError *err2 = nil;
    TTIOSpectrum *spec2 = [TTIOJcampDxReader readSpectrumFromPath:path
                                                            error:&err2];
    PASS(spec2 != nil, "legacy JCAMP-DX overload (no progress) still parses");
}

// --- mzTab --------------------------------------------------------------

static void testMzTabProgress(void)
{
    NSString *tmp = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    // Minimal mzTab v1.0 file with 3 PSM rows. Mirrors the synthetic
    // fixtures from TestMzTabReader.m.
    NSString *mztab =
        @"MTD\tmzTab-version\t1.0.0\n"
        @"MTD\tdescription\tprogress hook test\n"
        @"MTD\tms_run[1]-location\tfile:test.mzML\n"
        @"PSH\tsequence\taccession\tunique\tdatabase\tdatabase_version\t"
        @"search_engine\tsearch_engine_score[1]\tmodifications\tretention_time\t"
        @"charge\texp_mass_to_charge\tcalc_mass_to_charge\tspectra_ref\tpre\tpost\tstart\tend\tPSM_ID\n"
        @"PSM\tPEPTIDE1\tACC1\tnull\tnull\tnull\tMascot\t10.0\tnull\tnull\t2\t500.0\t500.0\tms_run[1]:scan=1\tnull\tnull\t1\t8\t1\n"
        @"PSM\tPEPTIDE2\tACC2\tnull\tnull\tnull\tMascot\t20.0\tnull\tnull\t2\t501.0\t501.0\tms_run[1]:scan=2\tnull\tnull\t1\t8\t2\n"
        @"PSM\tPEPTIDE3\tACC3\tnull\tnull\tnull\tMascot\t30.0\tnull\tnull\t2\t502.0\t502.0\tms_run[1]:scan=3\tnull\tnull\t1\t8\t3\n";
    NSString *path = [tmp stringByAppendingPathComponent:@"test.mztab"];
    [mztab writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSError *err = nil;
    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    TTIOMzTabImport *import = [TTIOMzTabReader readFromFilePath:path
                                                        progress:cb
                                                           error:&err];
    PASS(import != nil, "mzTab parses with progress");
    PASS(doneVals.count >= 1, "at least one mzTab progress fire");
    if (doneVals.count >= 1) {
        PASS([[doneVals lastObject] longLongValue] ==
             [[totalVals lastObject] longLongValue],
             "mzTab final fire stamps done == total");
        // 3 rows, cadence 500 → only final fire.
        PASS([[doneVals lastObject] longLongValue] == 3,
             "mzTab final fire reports 3 rows");
    }
    // Legacy overload still works.
    NSError *err2 = nil;
    TTIOMzTabImport *import2 = [TTIOMzTabReader readFromFilePath:path
                                                            error:&err2];
    PASS(import2 != nil, "legacy mzTab overload (no progress) still parses");
}

// Public entry point.
void testProgressSinkStageC(void)
{
    testMzMLProgress();
    testNmrMLProgress();
    testJcampDxProgress();
    testMzTabProgress();
}
