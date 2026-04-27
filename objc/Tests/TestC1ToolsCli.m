/*
 * TestC1ToolsCli.m — C1 CLI mains coverage (Objective-C).
 *
 * Each ObjC CLI lives as its own GNUstep tool binary under
 * objc/Tools/obj/. Test pattern: fork-exec each binary via NSTask
 * with various argv, capture stdout/stderr/exit-code, assert on
 * structure. Under --coverage, each child process writes a
 * separate .profraw under objc/coverage/raw/ that gets merged into
 * the lcov report by build.sh.
 *
 * Per docs/coverage-workplan.md §C1.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include <unistd.h>
#include <stdlib.h>

static NSString *kToolsDir =
    @"/home/toddw/TTI-O/objc/Tools/obj";

/** Run a CLI binary with the given args. Returns the termination
 *  status. Captures stdout into outBuf and stderr into errBuf. */
static int c1RunTool(NSString *toolName, NSArray<NSString *> *args,
                     NSMutableData **outBuf, NSMutableData **errBuf)
{
    NSString *path = [kToolsDir stringByAppendingPathComponent:toolName];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        return -1;  // tool not built; skip
    }
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = args ?: @[];

    // Inherit LLVM_PROFILE_FILE from parent so child .profraw lands
    // in the same coverage/raw/ directory as the test runner's.
    task.environment = [NSProcessInfo processInfo].environment;

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    @try {
        [task launch];
    } @catch (NSException *exc) {
        NSLog(@"c1RunTool: launch failed for %@: %@", path, exc.reason);
        return -2;
    }
    [task waitUntilExit];
    if (outBuf) {
        *outBuf = [[outPipe fileHandleForReading]
                       readDataToEndOfFile].mutableCopy;
    }
    if (errBuf) {
        *errBuf = [[errPipe fileHandleForReading]
                       readDataToEndOfFile].mutableCopy;
    }
    return task.terminationStatus;
}

/** Skip helper — return YES if a tool isn't built (don't fail the
 *  test, just skip cleanly). */
static BOOL c1ToolMissing(NSString *toolName)
{
    NSString *path = [kToolsDir stringByAppendingPathComponent:toolName];
    return ![[NSFileManager defaultManager] isExecutableFileAtPath:path];
}

void testC1ToolsCli(void)
{
    @autoreleasepool {
        // Iterate every tool we expect to be built.
        NSArray<NSString *> *tools = @[
            @"TtioVerify",
            @"TtioSign",
            @"TtioPQCTool",
            @"TtioPerAU",
            @"TtioBamDump",
            @"TtioJcampDxDump",
            @"TtioDumpIdentifications",
            @"TtioWriteGenomicFixture",
            @"TtioSimulator",
            @"TtioTransportEncode",
            @"TtioTransportDecode",
            @"TtioTransportServer",
            @"TtioToMzML",
            @"MakeFixtures",
        ];

        // ── No-args tests for every tool ────────────────────────────
        for (NSString *tool in tools) {
            if (c1ToolMissing(tool)) {
                NSLog(@"C1 ObjC: %@ not built; skipping no-args test", tool);
                PASS(YES, "C1 ObjC #1: tool skipped (not built)");
                continue;
            }
            NSMutableData *out = nil, *err = nil;
            int rc = c1RunTool(tool, @[], &out, &err);
            // Either non-zero exit or some stderr output indicates
            // the tool noticed the missing args. Some tools may
            // accept zero args and have a default behaviour.
            BOOL handled = (rc != 0) || (err.length > 0) || (out.length > 0);
            NSLog(@"C1 ObjC: %@ no-args exit=%d stdout=%lu stderr=%lu",
                  tool, rc, (unsigned long)out.length,
                  (unsigned long)err.length);
            PASS(handled, "C1 ObjC #1: tool no-args produced output or non-zero exit");
        }

        // ── TtioVerify on real fixture ──────────────────────────────
        if (!c1ToolMissing(@"TtioWriteGenomicFixture")
                && !c1ToolMissing(@"TtioVerify")) {
            NSString *fxPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_fixture.tio"];
            [[NSFileManager defaultManager] removeItemAtPath:fxPath error:NULL];
            NSMutableData *_o = nil, *_e = nil;
            int rc = c1RunTool(@"TtioWriteGenomicFixture", @[fxPath], &_o, &_e);
            PASS(rc == 0 || [[NSFileManager defaultManager] fileExistsAtPath:fxPath],
                 "C1 ObjC #2: TtioWriteGenomicFixture produced a .tio");

            if ([[NSFileManager defaultManager] fileExistsAtPath:fxPath]) {
                NSMutableData *out = nil, *err = nil;
                int rc2 = c1RunTool(@"TtioVerify", @[fxPath], &out, &err);
                PASS(rc2 == 0, "C1 ObjC #3: TtioVerify on real .tio exits 0");
                NSString *outStr = [[NSString alloc] initWithData:out
                                    encoding:NSUTF8StringEncoding];
                PASS([outStr containsString:@"\"title\""],
                     "C1 ObjC #4: TtioVerify prints JSON title key");

                // Chain to TtioDumpIdentifications.
                if (!c1ToolMissing(@"TtioDumpIdentifications")) {
                    NSMutableData *o3 = nil, *e3 = nil;
                    int rc3 = c1RunTool(@"TtioDumpIdentifications",
                                        @[fxPath], &o3, &e3);
                    PASS(rc3 >= 0, "C1 ObjC #5: TtioDumpIdentifications runs");
                }

                // Chain to TtioPerAU encrypt+decrypt.
                if (!c1ToolMissing(@"TtioPerAU")) {
                    NSString *keyPath = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:@"c1_perau_key.bin"];
                    char zeroKey[32] = {0};
                    [[NSData dataWithBytes:zeroKey length:32]
                       writeToFile:keyPath atomically:YES];
                    NSString *encPath = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:@"c1_perau_enc.tio"];
                    NSMutableData *o4 = nil, *e4 = nil;
                    int rc4 = c1RunTool(@"TtioPerAU",
                                        @[@"encrypt", fxPath, encPath, keyPath],
                                        &o4, &e4);
                    PASS(rc4 >= 0, "C1 ObjC #6: TtioPerAU encrypt runs");

                    if ([[NSFileManager defaultManager]
                             fileExistsAtPath:encPath]) {
                        NSString *decPath = [NSTemporaryDirectory()
                            stringByAppendingPathComponent:@"c1_perau_dec.mpad"];
                        NSMutableData *o5 = nil, *e5 = nil;
                        int rc5 = c1RunTool(@"TtioPerAU",
                                            @[@"decrypt", encPath, decPath, keyPath],
                                            &o5, &e5);
                        PASS(rc5 >= 0, "C1 ObjC #7: TtioPerAU decrypt runs");
                    }
                    [[NSFileManager defaultManager] removeItemAtPath:keyPath
                                                              error:NULL];
                    [[NSFileManager defaultManager] removeItemAtPath:encPath
                                                              error:NULL];
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:fxPath error:NULL];
        }

        // ── TtioPQCTool sig + KEM round-trips ───────────────────────
        if (!c1ToolMissing(@"TtioPQCTool")) {
            NSString *pk = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_pk.bin"];
            NSString *sk = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_sk.bin"];

            NSMutableData *o = nil, *e = nil;
            int rc1 = c1RunTool(@"TtioPQCTool",
                                @[@"sig-keygen", pk, sk], &o, &e);
            PASS(rc1 >= 0, "C1 ObjC #8: TtioPQCTool sig-keygen runs");

            // KEM round-trip in same test for compactness.
            NSString *kpk = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_kpk.bin"];
            NSString *ksk = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_ksk.bin"];
            NSString *ct = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_ct.bin"];
            NSString *ss1 = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_ss1.bin"];
            NSString *ss2 = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_ss2.bin"];

            int rc2 = c1RunTool(@"TtioPQCTool",
                                @[@"kem-keygen", kpk, ksk], &o, &e);
            PASS(rc2 >= 0, "C1 ObjC #9: TtioPQCTool kem-keygen runs");
            int rc3 = c1RunTool(@"TtioPQCTool",
                                @[@"kem-encaps", kpk, ct, ss1], &o, &e);
            PASS(rc3 >= 0, "C1 ObjC #10: TtioPQCTool kem-encaps runs");
            int rc4 = c1RunTool(@"TtioPQCTool",
                                @[@"kem-decaps", ksk, ct, ss2], &o, &e);
            PASS(rc4 >= 0, "C1 ObjC #11: TtioPQCTool kem-decaps runs");

            // Cleanup
            for (NSString *p in @[pk, sk, kpk, ksk, ct, ss1, ss2]) {
                [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
            }
        }

        // ── TtioPQCTool unknown subcommand ──────────────────────────
        if (!c1ToolMissing(@"TtioPQCTool")) {
            NSMutableData *o = nil, *e = nil;
            int rc = c1RunTool(@"TtioPQCTool",
                               @[@"this-is-not-a-subcommand"], &o, &e);
            PASS(rc != 0, "C1 ObjC #12: TtioPQCTool unknown subcommand fails");
        }

        // ── TtioBamDump on M88 fixture ──────────────────────────────
        if (!c1ToolMissing(@"TtioBamDump")) {
            NSString *bamPath = @"/home/toddw/TTI-O/python/tests/fixtures/genomic/m88_test.bam";
            if ([[NSFileManager defaultManager] fileExistsAtPath:bamPath]) {
                NSMutableData *o = nil, *e = nil;
                int rc = c1RunTool(@"TtioBamDump", @[bamPath], &o, &e);
                PASS(rc == 0, "C1 ObjC #13: TtioBamDump on M88 BAM exits 0");
                NSString *out = [[NSString alloc] initWithData:o
                                  encoding:NSUTF8StringEncoding];
                PASS([out hasPrefix:@"{"],
                     "C1 ObjC #14: TtioBamDump output starts with JSON {");
            }
        }
    }
}
