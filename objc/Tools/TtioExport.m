/*
 * TtioExport — OT8.
 *
 * Export one layer of a .tio container to a supported external format
 * via the exporter registry. Parallel to the Python `ttio export`
 * umbrella subcommand (ttio.tools.workbench_cli.cmd_export).
 *
 * Usage:
 *   TtioExport --format <fmt> --input <in.tio> [--layer <name>]
 *              --output <path> [--extra k=v]...
 *   TtioExport --list-formats
 *
 * Exit codes (mirror Python):
 *   0  success
 *   2  exporter failure or bad / missing args
 *   3  unsupported --format (or fasta/fastq, which are CLI-delegated)
 *
 * fasta / fastq are intentionally NOT handled here: they keep their
 * richer dedicated round-trip tools. ObjC has no unified fasta/fastq
 * export CLI, so we return 3 with a clear message — a documented
 * divergence from Python.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Export/TTIOExporterRegistry.h"
#include <stdio.h>

static const char *kCliDelegatedX[] = { "fasta", "fastq", NULL };

static BOOL eecIsDelegatedX(NSString *fmt)
{
    for (int i = 0; kCliDelegatedX[i]; i++) {
        if ([fmt isEqualToString:@(kCliDelegatedX[i])]) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *rawFormat = nil;
        NSString *input = nil;
        NSString *output = nil;
        NSString *layer = nil;
        NSMutableDictionary<NSString *, id> *opts = [NSMutableDictionary dictionary];
        BOOL listFormats = NO;

        for (int i = 1; i < argc; i++) {
            const char *a = argv[i];
            if (strcmp(a, "--list-formats") == 0) {
                listFormats = YES;
            } else if (strcmp(a, "--format") == 0 && i + 1 < argc) {
                rawFormat = @(argv[++i]);
            } else if (strcmp(a, "--input") == 0 && i + 1 < argc) {
                input = @(argv[++i]);
            } else if (strcmp(a, "--output") == 0 && i + 1 < argc) {
                output = @(argv[++i]);
            } else if (strcmp(a, "--layer") == 0 && i + 1 < argc) {
                layer = @(argv[++i]);
            } else if (strcmp(a, "--threads") == 0 && i + 1 < argc) {
                setenv("TTIO_THREADS", argv[++i], 1);
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
            for (NSString *f in [TTIOExporterRegistry supportedExportFormats]) {
                printf("%s\n", f.UTF8String);
            }
            return 0;
        }

        if (rawFormat == nil || input == nil || output == nil) {
            fprintf(stderr,
                "usage: TtioExport --format <fmt> --input <in.tio> "
                "[--layer <name>] --output <path> [--extra k=v]...\n"
                "       TtioExport --list-formats\n");
            return 2;
        }

        NSString *fmt = [TTIOExporterRegistry normalizeFormat:rawFormat];
        if (eecIsDelegatedX(fmt)) {
            fprintf(stderr,
                "format '%s' is delegated to the dedicated fasta/fastq tools\n",
                fmt.UTF8String);
            return 3;
        }
        if (![TTIOExporterRegistry isRegistryFormat:fmt]) {
            fprintf(stderr, "unsupported --format: %s\n", rawFormat.UTF8String);
            return 3;
        }

        NSError *err = nil;
        BOOL ok = [TTIOExporterRegistry exportFormat:fmt
                                             tioPath:input
                                               layer:layer
                                              output:output
                                             options:opts
                                               error:&err];
        if (!ok) {
            fprintf(stderr, "%s\n",
                    err.localizedDescription.UTF8String ?: "export failed");
            return 2;
        }
        printf("exported %s\n", output.UTF8String);
        return 0;
    }
}
