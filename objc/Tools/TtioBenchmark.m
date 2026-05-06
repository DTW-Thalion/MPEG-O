/*
 * TtioBenchmark — Objective-C microbenchmark harness for transport
 * encode + decode.
 *
 * Pairs with the Python stress runner
 * (python/tests/stress/test_provider_benchmark.py + .../test_*_benchmark.py)
 * and the Java sibling (global.thalion.ttio.tools.Benchmark) so
 * release-to-release perf tracking parity holds across all three
 * languages. The cross-language perf table in
 * docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md §3
 * is now reproducible from this binary.
 *
 * Inputs: an existing source .tio file. Times:
 *   - Transport encode in per-AU mode
 *   - Transport encode in Phase 2c-T bulk mode
 *   - Transport decode of each .tis back into a .tio
 *
 * Records timings + on-disk sizes to a JSON file. Default output:
 * objc/Tests/benchmark_results.json.
 *
 * Usage:
 *   TtioBenchmark <source.tio> [output.json]
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1.0e9;
}

static long file_size(NSString *path) {
    struct stat st;
    if (stat(path.UTF8String, &st) != 0) return -1;
    return (long)st.st_size;
}

static NSString *encode_one(NSString *src, NSString *tmpDir, BOOL bulk,
                              double *outSeconds, long *outBytes) {
    NSString *tis = [tmpDir stringByAppendingPathComponent:
                     bulk ? @"bulk.tis" : @"per_au.tis"];
    NSError *err = nil;
    double t0 = monotonic_seconds();
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    if (!ds) {
        fprintf(stderr, "open failed: %s\n",
                err.localizedDescription.UTF8String ?: "unknown");
        return nil;
    }
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithOutputPath:tis];
    tw.useBulkMode = bulk;
    BOOL ok = [tw writeDataset:ds error:&err];
    [tw close];
    if (!ok) {
        fprintf(stderr, "encode failed: %s\n",
                err.localizedDescription.UTF8String ?: "unknown");
        return nil;
    }
    *outSeconds = monotonic_seconds() - t0;
    *outBytes = file_size(tis);
    return tis;
}

static BOOL decode_one(NSString *tis, NSString *rtTio,
                       double *outSeconds, long *outBytes) {
    NSError *err = nil;
    double t0 = monotonic_seconds();
    TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithInputPath:tis];
    BOOL ok = [tr writeTtioToPath:rtTio error:&err];
    if (!ok) {
        fprintf(stderr, "decode failed: %s\n",
                err.localizedDescription.UTF8String ?: "unknown");
        return NO;
    }
    *outSeconds = monotonic_seconds() - t0;
    *outBytes = file_size(rtTio);
    return YES;
}

static void emit_kv(NSMutableString *out, NSString *key, id value, BOOL last) {
    [out appendFormat:@"    \"%@\": ", key];
    if ([value isKindOfClass:[NSString class]]) {
        [out appendFormat:@"\"%@\"", [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    } else if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *n = (NSNumber *)value;
        if (strcmp(n.objCType, @encode(BOOL)) == 0) {
            [out appendString:n.boolValue ? @"true" : @"false"];
        } else {
            [out appendFormat:@"%@", n];
        }
    } else {
        [out appendString:@"null"];
    }
    [out appendString:last ? @"\n" : @",\n"];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: TtioBenchmark <source.tio> [output.json]\n"
                    "Times transport encode + decode (per-AU and Phase 2c-T bulk)\n"
                    "and writes a JSON summary suitable for release-to-release diffs.\n");
            return 2;
        }
        NSString *src = [NSString stringWithUTF8String:argv[1]];
        NSString *out = argc > 2
            ? [NSString stringWithUTF8String:argv[2]]
            : @"objc/Tests/benchmark_results.json";

        long srcBytes = file_size(src);
        if (srcBytes < 0) {
            fprintf(stderr, "source .tio not found: %s\n", src.UTF8String);
            return 1;
        }

        NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [@"ttio_objc_bench_" stringByAppendingString:
                             [NSUUID.UUID.UUIDString substringToIndex:8]]];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];

        double sEncPerAu = 0, sEncBulk = 0, sDecPerAu = 0, sDecBulk = 0;
        long bEncPerAu = 0, bEncBulk = 0, bDecPerAu = 0, bDecBulk = 0;
        NSString *perAuTis = encode_one(src, tmpDir, NO, &sEncPerAu, &bEncPerAu);
        NSString *bulkTis  = encode_one(src, tmpDir, YES, &sEncBulk,  &bEncBulk);
        if (!perAuTis || !bulkTis) return 1;
        NSString *perAuRt = [tmpDir stringByAppendingPathComponent:@"per_au_rt.tio"];
        NSString *bulkRt  = [tmpDir stringByAppendingPathComponent:@"bulk_rt.tio"];
        if (!decode_one(perAuTis, perAuRt, &sDecPerAu, &bDecPerAu)) return 1;
        if (!decode_one(bulkTis,  bulkRt,  &sDecBulk,  &bDecBulk))  return 1;

        // Build the JSON output by hand; minimal output, matches the
        // Java + Python harness shape so cross-language diffs work.
        NSMutableString *json = [NSMutableString string];
        [json appendString:@"{\n"];
        [json appendFormat:@"  \"language\": \"objc\",\n"];
        [json appendFormat:@"  \"source_tio\": \"%@\",\n", src];
        [json appendFormat:@"  \"source_bytes\": %ld,\n", srcBytes];
        [json appendFormat:@"  \"timestamp_unix\": %ld,\n",
            (long)[[NSDate date] timeIntervalSince1970]];
        [json appendString:@"  \"scenarios\": {\n"];
        [json appendString:@"    \"transport_encode_per_au\": {\n"];
        emit_kv(json, @"  seconds", @(round(sEncPerAu * 10000) / 10000), NO);
        emit_kv(json, @"  tis_bytes", @(bEncPerAu), NO);
        emit_kv(json, @"  bulk", @NO, YES);
        [json appendString:@"    },\n"];
        [json appendString:@"    \"transport_encode_bulk\": {\n"];
        emit_kv(json, @"  seconds", @(round(sEncBulk * 10000) / 10000), NO);
        emit_kv(json, @"  tis_bytes", @(bEncBulk), NO);
        emit_kv(json, @"  bulk", @YES, YES);
        [json appendString:@"    },\n"];
        [json appendString:@"    \"transport_decode_per_au\": {\n"];
        emit_kv(json, @"  seconds", @(round(sDecPerAu * 10000) / 10000), NO);
        emit_kv(json, @"  rt_tio_bytes", @(bDecPerAu), YES);
        [json appendString:@"    },\n"];
        [json appendString:@"    \"transport_decode_bulk\": {\n"];
        emit_kv(json, @"  seconds", @(round(sDecBulk * 10000) / 10000), NO);
        emit_kv(json, @"  rt_tio_bytes", @(bDecBulk), YES);
        [json appendString:@"    }\n"];
        [json appendString:@"  }\n"];
        [json appendString:@"}\n"];

        NSError *werr = nil;
        // Make sure parent dir exists.
        NSString *outDir = [out stringByDeletingLastPathComponent];
        if (outDir.length > 0) {
            [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                                       withIntermediateDirectories:YES
                                                        attributes:nil error:nil];
        }
        if (![json writeToFile:out atomically:YES
                       encoding:NSUTF8StringEncoding error:&werr]) {
            fprintf(stderr, "write JSON failed: %s\n",
                    werr.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
        fprintf(stderr, "benchmark results written to %s\n", out.UTF8String);

        // Best-effort tmp cleanup.
        [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:NULL];
    }
    return 0;
}
