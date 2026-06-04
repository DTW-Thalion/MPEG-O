/*
 * TtioEncode — OT8.
 *
 * Encode one or more source files of a given format into a .tio
 * container via the importer registry. Parallel to the Python
 * `ttio encode` umbrella subcommand
 * (ttio.tools.workbench_cli.cmd_encode).
 *
 * Usage:
 *   TtioEncode --format <fmt> --input <path> [--input <path>...]
 *              --output <out.tio> [--extra k=v]...
 *   TtioEncode --list-formats
 *
 * Exit codes (mirror Python):
 *   0  success
 *   2  importer failure or bad / missing args
 *   3  unsupported --format (or fasta/fastq, which are CLI-delegated)
 *
 * fasta / fastq are intentionally NOT handled here: they keep their
 * richer dedicated round-trip tools (TtioFastaRoundTrip /
 * TtioFastqRoundTrip). ObjC has no unified fasta/fastq import CLI, so
 * we return 3 with a clear message — a documented divergence from
 * Python, which delegates to its dedicated import CLIs.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Import/TTIOImporterRegistry.h"
#include <stdio.h>

static const char *kCliDelegated[] = { "fasta", "fastq", NULL };

static BOOL eecIsDelegated(NSString *fmt)
{
    for (int i = 0; kCliDelegated[i]; i++) {
        if ([fmt isEqualToString:@(kCliDelegated[i])]) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *rawFormat = nil;
        NSString *output = nil;
        NSMutableArray<NSString *> *inputs = [NSMutableArray array];
        NSMutableDictionary<NSString *, id> *opts = [NSMutableDictionary dictionary];
        BOOL listFormats = NO;

        for (int i = 1; i < argc; i++) {
            const char *a = argv[i];
            if (strcmp(a, "--list-formats") == 0) {
                listFormats = YES;
            } else if (strcmp(a, "--format") == 0 && i + 1 < argc) {
                rawFormat = @(argv[++i]);
            } else if (strcmp(a, "--input") == 0 && i + 1 < argc) {
                [inputs addObject:@(argv[++i])];
            } else if (strcmp(a, "--output") == 0 && i + 1 < argc) {
                output = @(argv[++i]);
            } else if (strcmp(a, "--extra") == 0 && i + 1 < argc) {
                NSString *kv = @(argv[++i]);
                NSRange eq = [kv rangeOfString:@"="];
                if (eq.location != NSNotFound) {
                    opts[[kv substringToIndex:eq.location]] =
                        [kv substringFromIndex:eq.location + 1];
                }
            } else {
                fprintf(stderr, "unrecognized argument: %s\n", a);
                return 2;
            }
        }

        if (listFormats) {
            for (NSString *f in [TTIOImporterRegistry supportedEncodeFormats]) {
                printf("%s\n", f.UTF8String);
            }
            return 0;
        }

        if (rawFormat == nil || output == nil || inputs.count == 0) {
            fprintf(stderr,
                "usage: TtioEncode --format <fmt> --input <path> "
                "[--input <path>...] --output <out.tio> [--extra k=v]...\n"
                "       TtioEncode --list-formats\n");
            return 2;
        }

        NSString *fmt = [TTIOImporterRegistry normalizeFormat:rawFormat];
        if (eecIsDelegated(fmt)) {
            fprintf(stderr,
                "format '%s' is delegated to the dedicated fasta/fastq tools\n",
                fmt.UTF8String);
            return 3;
        }
        if (![TTIOImporterRegistry isRegistryFormat:fmt]) {
            fprintf(stderr, "unsupported --format: %s\n", rawFormat.UTF8String);
            return 3;
        }

        NSError *err = nil;
        BOOL ok = [TTIOImporterRegistry encodeFormat:fmt
                                              inputs:inputs
                                              output:output
                                             options:opts
                                               error:&err];
        if (!ok) {
            fprintf(stderr, "%s\n",
                    err.localizedDescription.UTF8String ?: "encode failed");
            return 2;
        }
        printf("encoded %s\n", output.UTF8String);
        return 0;
    }
}
