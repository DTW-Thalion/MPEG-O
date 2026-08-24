/*
 * TtioGfaDump — canonical-JSON dump of a GFA 1.x file or a stored
 * assembly graph, plus the M98 conformance write/emit modes.
 *
 * Usage:
 *     TtioGfaDump <input.gfa|input.tio> [--graph NAME]
 *     TtioGfaDump <input.gfa> --write-tio <out.tio> [--graph NAME]
 *     TtioGfaDump <input.tio> --emit-gfa <out.gfa> [--graph NAME]
 *
 * The JSON document is byte-identical to Python's
 * `json.dumps(payload, sort_keys=True, indent=2)` plus a trailing
 * newline; the same shape is produced by the Python
 * `python -m ttio.importers.gfa_dump` CLI and the Java `GfaDump`
 * CLI. The M98 conformance harness diffs the three outputs and
 * drives the 3x3 container matrix through the write/emit modes.
 * Canonical serialisation is by hand, the TtioBamDump precedent.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Assembly/TTIOWrittenAssemblyGraph.h"
#import "Assembly/TTIOGraphSegment.h"
#import "Assembly/TTIOGraphLink.h"
#import "Assembly/TTIOGraphPath.h"
#import "Assembly/TTIOAssemblyGraph.h"
#import "Import/TTIOGfaReader.h"
#import "Export/TTIOGfaWriter.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSpectralDataset+AssemblyWrite.h"
#include <openssl/md5.h>

// ── Canonical JSON helpers (TtioBamDump pattern) ────────────────────

static NSString *gdHexFromMD5(NSData *bytes)
{
    unsigned char digest[MD5_DIGEST_LENGTH];
    MD5(bytes.bytes, bytes.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static void gdAppendJsonString(NSMutableString *out, NSString *s)
{
    [out appendString:@"\""];
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '\"': [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\b': [out appendString:@"\\b"]; break;
            case '\f': [out appendString:@"\\f"]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\r': [out appendString:@"\\r"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            default:
                if (c < 0x20) {
                    [out appendFormat:@"\\u%04x", (unsigned)c];
                } else if (c < 0x7F) {
                    [out appendFormat:@"%c", (char)c];
                } else {
                    // Python ensure_ascii=True default -> \uXXXX.
                    [out appendFormat:@"\\u%04x", (unsigned)c];
                }
        }
    }
    [out appendString:@"\""];
}

static NSString *gdIndent(NSUInteger level)
{
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < level * 2; i++) [s appendString:@" "];
    return s;
}

static void gdAppendStringArray(NSMutableString *out, NSArray<NSString *> *arr,
                                  NSUInteger indentLevel)
{
    if (arr.count == 0) { [out appendString:@"[]"]; return; }
    [out appendString:@"[\n"];
    NSString *itemIndent = gdIndent(indentLevel + 1);
    for (NSUInteger i = 0; i < arr.count; i++) {
        [out appendString:itemIndent];
        gdAppendJsonString(out, arr[i]);
        if (i + 1 < arr.count) [out appendString:@","];
        [out appendString:@"\n"];
    }
    [out appendString:gdIndent(indentLevel)];
    [out appendString:@"]"];
}

/** Array of JSON objects, each given as ordered @[key, value] pairs
 *  (keys pre-sorted; values NSString or NSNumber ints). */
static void gdAppendObjectArray(NSMutableString *out,
                                  NSArray<NSArray<NSArray *> *> *objs,
                                  NSUInteger indentLevel)
{
    if (objs.count == 0) { [out appendString:@"[]"]; return; }
    [out appendString:@"[\n"];
    NSString *objIndent = gdIndent(indentLevel + 1);
    NSString *keyIndent = gdIndent(indentLevel + 2);
    for (NSUInteger i = 0; i < objs.count; i++) {
        NSArray<NSArray *> *pairs = objs[i];
        [out appendString:objIndent];
        [out appendString:@"{\n"];
        for (NSUInteger k = 0; k < pairs.count; k++) {
            [out appendString:keyIndent];
            gdAppendJsonString(out, pairs[k][0]);
            [out appendString:@": "];
            id v = pairs[k][1];
            if ([v isKindOfClass:[NSNumber class]]) {
                [out appendFormat:@"%lld", [v longLongValue]];
            } else {
                gdAppendJsonString(out, v);
            }
            if (k + 1 < pairs.count) [out appendString:@","];
            [out appendString:@"\n"];
        }
        [out appendString:objIndent];
        [out appendString:@"}"];
        if (i + 1 < objs.count) [out appendString:@","];
        [out appendString:@"\n"];
    }
    [out appendString:gdIndent(indentLevel)];
    [out appendString:@"]"];
}

static void gdAppendUInt64Array(NSMutableString *out, const uint64_t *vals,
                                  NSUInteger n, NSUInteger indentLevel)
{
    if (n == 0) { [out appendString:@"[]"]; return; }
    [out appendString:@"[\n"];
    NSString *itemIndent = gdIndent(indentLevel + 1);
    for (NSUInteger i = 0; i < n; i++) {
        [out appendString:itemIndent];
        [out appendFormat:@"%llu", (unsigned long long)vals[i]];
        if (i + 1 < n) [out appendString:@","];
        [out appendString:@"\n"];
    }
    [out appendString:gdIndent(indentLevel)];
    [out appendString:@"]"];
}

static void gdAppendUInt32Array(NSMutableString *out, const uint32_t *vals,
                                  NSUInteger n, NSUInteger indentLevel)
{
    if (n == 0) { [out appendString:@"[]"]; return; }
    [out appendString:@"[\n"];
    NSString *itemIndent = gdIndent(indentLevel + 1);
    for (NSUInteger i = 0; i < n; i++) {
        [out appendString:itemIndent];
        [out appendFormat:@"%u", (unsigned)vals[i]];
        if (i + 1 < n) [out appendString:@","];
        [out appendString:@"\n"];
    }
    [out appendString:gdIndent(indentLevel)];
    [out appendString:@"]"];
}

static void gdAppendKeyString(NSMutableString *out, NSString *key,
                                NSString *val, NSUInteger lvl, BOOL comma)
{
    [out appendString:gdIndent(lvl)];
    gdAppendJsonString(out, key);
    [out appendString:@": "];
    gdAppendJsonString(out, val);
    [out appendString:comma ? @",\n" : @"\n"];
}

static void gdAppendKeyInt(NSMutableString *out, NSString *key,
                             long long val, NSUInteger lvl, BOOL comma)
{
    [out appendString:gdIndent(lvl)];
    gdAppendJsonString(out, key);
    [out appendString:@": "];
    [out appendFormat:@"%lld", val];
    [out appendString:comma ? @",\n" : @"\n"];
}

// ── Graph loading ───────────────────────────────────────────────────

static TTIOWrittenAssemblyGraph *gdLoad(NSString *path, NSString *graphName)
{
    if ([path.lowercaseString hasSuffix:@".tio"]) {
        NSError *err = nil;
        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        if (!ds) {
            fprintf(stderr, "TtioGfaDump: open failed: %s\n",
                    err.localizedDescription.UTF8String ?: "(unknown)");
            return nil;
        }
        TTIOAssemblyGraph *g = ds.assemblyGraphs[graphName];
        if (!g) {
            fprintf(stderr, "TtioGfaDump: no assembly graph '%s'\n",
                    graphName.UTF8String);
            [ds closeFile];
            return nil;
        }
        TTIOWrittenAssemblyGraph *written = [g writtenGraphWithError:&err];
        if (!written) {
            fprintf(stderr, "TtioGfaDump: graph read failed: %s\n",
                    err.localizedDescription.UTF8String ?: "(unknown)");
        }
        [ds closeFile];
        return written;
    }
    NSError *err = nil;
    TTIOWrittenAssemblyGraph *g = [TTIOGfaReader graphFromPath:path
                                                         error:&err];
    if (!g) {
        fprintf(stderr, "TtioGfaDump: parse failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
    }
    return g;
}

// ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <input.gfa|input.tio> "
                    "[--graph NAME] [--write-tio OUT] [--emit-gfa OUT]\n",
                    argv[0]);
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *graphName = @"graph_0001";
        NSString *writeTio = nil;
        NSString *emitGfa = nil;
        for (int i = 2; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--graph"] && i + 1 < argc) {
                graphName = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--write-tio"] && i + 1 < argc) {
                writeTio = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--emit-gfa"] && i + 1 < argc) {
                emitGfa = [NSString stringWithUTF8String:argv[++i]];
            }
        }

        if (writeTio) {
            NSError *err = nil;
            TTIOWrittenAssemblyGraph *g = [TTIOGfaReader graphFromPath:path
                                                                 error:&err];
            if (!g) {
                fprintf(stderr, "TtioGfaDump: parse failed: %s\n",
                        err.localizedDescription.UTF8String ?: "(unknown)");
                return 1;
            }
            if (![TTIOSpectralDataset writeMinimalToPath:writeTio
                                                   title:@"M98"
                                     isaInvestigationId:@"M98"
                                                  msRuns:@{}
                                             genomicRuns:nil
                                          assemblyGraphs:@{graphName: g}
                                         identifications:nil
                                         quantifications:nil
                                       provenanceRecords:nil
                                                   error:&err]) {
                fprintf(stderr, "TtioGfaDump: write failed: %s\n",
                        err.localizedDescription.UTF8String ?: "(unknown)");
                return 1;
            }
            return 0;
        }

        if (emitGfa) {
            TTIOWrittenAssemblyGraph *g = gdLoad(path, graphName);
            if (!g) return 1;
            NSError *err = nil;
            if (![TTIOGfaWriter writeGraph:g toPath:emitGfa error:&err]) {
                fprintf(stderr, "TtioGfaDump: emit failed: %s\n",
                        err.localizedDescription.UTF8String ?: "(unknown)");
                return 1;
            }
            return 0;
        }

        TTIOWrittenAssemblyGraph *g = gdLoad(path, graphName);
        if (!g) return 1;

        NSMutableData *seqs = [NSMutableData data];
        for (TTIOGraphSegment *s in g.segments) {
            if (s.sequence) [seqs appendData:s.sequence];
        }
        const uint32_t *types = (const uint32_t *)g.lineTypes.bytes;
        const uint64_t *rows = (const uint64_t *)g.lineRows.bytes;
        NSUInteger lineCount = g.lineCount;

        NSMutableArray *linkObjs = [NSMutableArray array];
        for (TTIOGraphLink *l in g.links) {
            [linkObjs addObject:@[
                @[@"from", l.fromSegment],
                @[@"from_orient", l.fromOrient],
                @[@"overlap", l.overlap],
                @[@"tags", l.tags],
                @[@"to", l.toSegment],
                @[@"to_orient", l.toOrient],
            ]];
        }
        NSMutableArray *pathObjs = [NSMutableArray array];
        for (TTIOGraphPath *p in g.paths) {
            [pathObjs addObject:@[
                @[@"name", p.name],
                @[@"overlaps", p.overlaps],
                @[@"segment_list", p.segmentList],
                @[@"tags", p.tags],
            ]];
        }
        NSMutableArray *segObjs = [NSMutableArray array];
        for (TTIOGraphSegment *s in g.segments) {
            [segObjs addObject:@[
                @[@"length", @(s.sequence ? s.sequence.length : 0)],
                @[@"name", s.name],
                @[@"seq_missing", @(s.sequence ? 0 : 1)],
                @[@"tags", s.tags],
            ]];
        }

        // ── Emit canonical JSON, keys alphabetically sorted:
        //   extra_count, extras, final_newline, gfa_version,
        //   line_rows, line_types, link_count, links, path_count,
        //   paths, producer, segment_count, segments, sequences_md5
        NSMutableString *out = [NSMutableString string];
        [out appendString:@"{\n"];

        gdAppendKeyInt(out, @"extra_count", (long long)g.extras.count, 1, YES);

        [out appendString:gdIndent(1)];
        gdAppendJsonString(out, @"extras");
        [out appendString:@": "];
        gdAppendStringArray(out, g.extras, 1);
        [out appendString:@",\n"];

        gdAppendKeyInt(out, @"final_newline", g.finalNewline ? 1 : 0, 1, YES);
        gdAppendKeyString(out, @"gfa_version", g.gfaVersion ?: @"", 1, YES);

        [out appendString:gdIndent(1)];
        gdAppendJsonString(out, @"line_rows");
        [out appendString:@": "];
        gdAppendUInt64Array(out, rows, lineCount, 1);
        [out appendString:@",\n"];

        [out appendString:gdIndent(1)];
        gdAppendJsonString(out, @"line_types");
        [out appendString:@": "];
        gdAppendUInt32Array(out, types, lineCount, 1);
        [out appendString:@",\n"];

        gdAppendKeyInt(out, @"link_count", (long long)g.links.count, 1, YES);

        [out appendString:gdIndent(1)];
        gdAppendJsonString(out, @"links");
        [out appendString:@": "];
        gdAppendObjectArray(out, linkObjs, 1);
        [out appendString:@",\n"];

        gdAppendKeyInt(out, @"path_count", (long long)g.paths.count, 1, YES);

        [out appendString:gdIndent(1)];
        gdAppendJsonString(out, @"paths");
        [out appendString:@": "];
        gdAppendObjectArray(out, pathObjs, 1);
        [out appendString:@",\n"];

        gdAppendKeyString(out, @"producer", g.producer ?: @"", 1, YES);
        gdAppendKeyInt(out, @"segment_count", (long long)g.segments.count,
                        1, YES);

        [out appendString:gdIndent(1)];
        gdAppendJsonString(out, @"segments");
        [out appendString:@": "];
        gdAppendObjectArray(out, segObjs, 1);
        [out appendString:@",\n"];

        // sequences_md5 (last — no trailing comma)
        gdAppendKeyString(out, @"sequences_md5", gdHexFromMD5(seqs), 1, NO);

        [out appendString:@"}\n"];

        fputs(out.UTF8String, stdout);
    }
    return 0;
}
