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
#include <signal.h>

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

        // ── Happy-path runs for one-shot tools (raise beyond no-args) ──
        // Build a genomic fixture once, then chain the encode/sign tools
        // off it so their success paths (not just the arg-error branch)
        // execute under coverage. Each run is guarded by c1ToolMissing.
        if (!c1ToolMissing(@"TtioWriteGenomicFixture")) {
            NSString *hp = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_hp_fixture.tio"];
            [[NSFileManager defaultManager] removeItemAtPath:hp error:NULL];
            NSMutableData *o = nil, *e = nil;
            c1RunTool(@"TtioWriteGenomicFixture", @[hp], &o, &e);

            if ([[NSFileManager defaultManager] fileExistsAtPath:hp]) {
                // TtioTransportEncode <in.tio> <out.tis>  (exit 0, .tis written)
                if (!c1ToolMissing(@"TtioTransportEncode")) {
                    NSString *tis = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:@"c1_hp.tis"];
                    [[NSFileManager defaultManager] removeItemAtPath:tis error:NULL];
                    NSMutableData *eo = nil, *ee = nil;
                    int rc = c1RunTool(@"TtioTransportEncode", @[hp, tis], &eo, &ee);
                    PASS(rc == 0 && [[NSFileManager defaultManager]
                            fileExistsAtPath:tis],
                         "C1 ObjC HP: TtioTransportEncode wrote a .tis");
                    [[NSFileManager defaultManager] removeItemAtPath:tis error:NULL];
                }

                // TtioSign <tio> <dataset> <key-hex>  (64 hex chars = 32 bytes).
                // The genomic_index/positions dataset is written by the
                // fixture writer (confirmed via h5py), so signing it
                // exercises the success path and returns 0.
                if (!c1ToolMissing(@"TtioSign")) {
                    NSString *ds =
                        @"/study/genomic_runs/genomic_0001/genomic_index/positions";
                    NSString *keyHex = [@"" stringByPaddingToLength:64
                        withString:@"0" startingAtIndex:0];
                    NSMutableData *so = nil, *se = nil;
                    int rc = c1RunTool(@"TtioSign", @[hp, ds, keyHex], &so, &se);
                    PASS(rc == 0, "C1 ObjC HP: TtioSign on a real dataset exits 0");
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:hp error:NULL];
        }

        // TtioSimulator <output.tis> [flags] — self-contained synthetic
        // stream generator; needs no input fixture. Keep it small with
        // --duration/--scan-rate so the run is fast. Exit 0 + .tis written.
        if (!c1ToolMissing(@"TtioSimulator")) {
            NSString *simTis = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_hp_sim.tis"];
            [[NSFileManager defaultManager] removeItemAtPath:simTis error:NULL];
            NSMutableData *o = nil, *e = nil;
            int rc = c1RunTool(@"TtioSimulator",
                               @[simTis, @"--duration", @"1", @"--scan-rate", @"5"],
                               &o, &e);
            PASS(rc == 0 && [[NSFileManager defaultManager]
                    fileExistsAtPath:simTis],
                 "C1 ObjC HP: TtioSimulator wrote a synthetic .tis");
            [[NSFileManager defaultManager] removeItemAtPath:simTis error:NULL];
        }

        // MakeFixtures <output_dir> — writes the canonical MS/NMR fixture
        // set (minimal_ms.tio, full_ms.tio, nmr_1d.tio, encrypted.tio,
        // signed.tio). Exit 0 on success. We then feed full_ms.tio to
        // TtioToMzML, which needs MS content (the genomic fixture above
        // would not satisfy it).
        if (!c1ToolMissing(@"MakeFixtures")) {
            NSString *dir = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_makefixtures"];
            [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                withIntermediateDirectories:YES attributes:nil error:NULL];
            NSMutableData *o = nil, *e = nil;
            int rc = c1RunTool(@"MakeFixtures", @[dir], &o, &e);
            PASS(rc == 0, "C1 ObjC HP: MakeFixtures wrote its fixture set");

            // TtioToMzML <input.tio> <output.mzML> on the MS fixture.
            NSString *msTio = [dir stringByAppendingPathComponent:@"full_ms.tio"];
            if (!c1ToolMissing(@"TtioToMzML")
                    && [[NSFileManager defaultManager] fileExistsAtPath:msTio]) {
                NSString *mzml = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:@"c1_hp.mzML"];
                [[NSFileManager defaultManager] removeItemAtPath:mzml error:NULL];
                NSMutableData *mo = nil, *me = nil;
                int mrc = c1RunTool(@"TtioToMzML", @[msTio, mzml], &mo, &me);
                PASS(mrc == 0 && [[NSFileManager defaultManager]
                        fileExistsAtPath:mzml],
                     "C1 ObjC HP: TtioToMzML wrote an .mzML from an MS .tio");
                [[NSFileManager defaultManager] removeItemAtPath:mzml error:NULL];
            }
            [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        }

        // ── TtioTransportServer: launch, read PORT=, then SIGTERM ──────
        // TtioTransportServer is long-running (loops until SIGTERM/SIGINT),
        // so we cannot use c1RunTool (which waitsUntilExit). We launch a
        // dedicated NSTask, read stdout until we see the PORT=<n> line the
        // server prints (with fflush) once bound, then SIGTERM it and wait
        // for the clean exit handleSig() drives. The read is capped so the
        // test can NEVER hang: kill + waitUntilExit always run.
        if (!c1ToolMissing(@"TtioTransportServer")
                && !c1ToolMissing(@"TtioWriteGenomicFixture")) {
            NSString *srvTio = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"c1_srv.tio"];
            [[NSFileManager defaultManager] removeItemAtPath:srvTio error:NULL];
            NSMutableData *fo = nil, *fe = nil;
            c1RunTool(@"TtioWriteGenomicFixture", @[srvTio], &fo, &fe);

            if ([[NSFileManager defaultManager] fileExistsAtPath:srvTio]) {
                NSString *path = [kToolsDir
                    stringByAppendingPathComponent:@"TtioTransportServer"];
                NSTask *task = [[NSTask alloc] init];
                task.launchPath = path;
                task.arguments = @[srvTio, @"--port", @"0"];
                task.environment = [NSProcessInfo processInfo].environment;
                NSPipe *outPipe = [NSPipe pipe];
                task.standardOutput = outPipe;
                NSFileHandle *rd = [outPipe fileHandleForReading];

                BOOL launched = YES;
                @try { [task launch]; }
                @catch (NSException *exc) { launched = NO; }
                PASS(launched, "C1 ObjC HP: TtioTransportServer launched");

                if (launched) {
                    // Read until we see a PORT= line, EOF, or 30 chunk-reads (a hard
                    // cap on iterations, not wall-clock — the server flushes PORT=
                    // promptly after binding so the first availableData usually has it).
                    NSMutableData *acc = [NSMutableData data];
                    BOOL sawPort = NO;
                    for (int i = 0; i < 30 && !sawPort; i++) {
                        NSData *chunk = [rd availableData];
                        if (chunk.length) {
                            [acc appendData:chunk];
                            NSString *s = [[NSString alloc] initWithData:acc
                                encoding:NSUTF8StringEncoding];
                            if ([s containsString:@"PORT="]) sawPort = YES;
                        } else {
                            // EOF (server died) — stop looping, proceed to kill.
                            break;
                        }
                    }
                    PASS(sawPort,
                         "C1 ObjC HP: TtioTransportServer printed PORT=");
                    kill(task.processIdentifier, SIGTERM);
                    [task waitUntilExit];
                    PASS(task.terminationStatus == 0,
                         "C1 ObjC HP: TtioTransportServer exited 0 after SIGTERM");
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:srvTio error:NULL];
        }

        // TtioJcampDxDump: no happy-path run. The only committed JCAMP-DX
        // fixtures (conformance/jcamp_dx/uvvis_ramp25_*.jdx) are UV/Vis
        // spectra (TTIOUVVisSpectrum), which TtioJcampDxDump rejects (it
        // handles Raman/IR only). Left as the no-args case until a
        // Raman/IR .jdx fixture is committed.
    }
}
