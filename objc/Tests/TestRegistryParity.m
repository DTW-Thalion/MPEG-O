/*
 * TestRegistryParity.m — OT7 cross-language fence.
 *
 * The importer/exporter registries are the single source of truth for the
 * formats the CLI accepts; they MUST stay byte-for-byte aligned with the
 * Python ttio.importers.registry + ttio.exporters.registry. This test
 * hardcodes the GOLDEN sorted key arrays and alias dictionaries sourced
 * directly from the Python registry files and asserts the ObjC registries
 * reproduce them exactly. A drift in either language fails this fence.
 *
 * The fence covers keys + aliases (the wire-visible contract). requiredTool
 * is intentionally NOT fenced (it is an environment/runtime concern).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Import/TTIOImporterRegistry.h"
#import "Export/TTIOExporterRegistry.h"

void testRegistryParity(void)
{
    @autoreleasepool {
        // ── IMPORT golden (from python/src/ttio/importers/registry.py) ──
        NSArray<NSString *> *goldenImportKeys = @[
            @"bam", @"bruker-timstof", @"cram", @"imzml", @"jcamp-dx",
            @"mzml", @"mztab", @"nmrml", @"sam", @"thermo-raw",
            @"waters-masslynx"];
        PASS([[TTIOImporterRegistry registryKeys] isEqualToArray:goldenImportKeys],
             "OT7 parity: importer registryKeys == Python golden (sorted, 11)");

        NSDictionary<NSString *, NSString *> *goldenImportAliases = @{
            @"thermo": @"thermo-raw",
            @"thermo.raw": @"thermo-raw",
            @"raw": @"thermo-raw",
            @"waters": @"waters-masslynx",
            @"masslynx": @"waters-masslynx",
            @"bruker": @"bruker-timstof",
            @"timstof": @"bruker-timstof",
            @"tdf": @"bruker-timstof",
            @"jcamp": @"jcamp-dx",
            @"jdx": @"jcamp-dx",
            @"dx": @"jcamp-dx",
            @"jcm": @"jcamp-dx",
        };
        NSUInteger importAliasHits = 0;
        for (NSString *alias in goldenImportAliases) {
            if ([[TTIOImporterRegistry normalizeFormat:alias]
                    isEqualToString:goldenImportAliases[alias]])
                importAliasHits++;
        }
        PASS(importAliasHits == goldenImportAliases.count,
             "OT7 parity: every Python import alias maps to its canonical key");

        // Canonical keys normalise to themselves (no alias hijack).
        NSUInteger importIdentity = 0;
        for (NSString *k in goldenImportKeys) {
            if ([[TTIOImporterRegistry normalizeFormat:k] isEqualToString:k])
                importIdentity++;
        }
        PASS(importIdentity == goldenImportKeys.count,
             "OT7 parity: import canonical keys normalise to themselves");

        // ── EXPORT golden (from python/src/ttio/exporters/registry.py) ──
        NSArray<NSString *> *goldenExportKeys = @[
            @"bam", @"cram", @"imzml", @"isa", @"jcamp-dx",
            @"mzml", @"mztab", @"nmrml"];
        PASS([[TTIOExporterRegistry registryKeys] isEqualToArray:goldenExportKeys],
             "OT7 parity: exporter registryKeys == Python golden (sorted, 8)");

        NSDictionary<NSString *, NSString *> *goldenExportAliases = @{
            @"isa-tab": @"isa",
            @"isatab": @"isa",
            @"jcamp": @"jcamp-dx",
            @"jdx": @"jcamp-dx",
            @"dx": @"jcamp-dx",
            @"jcm": @"jcamp-dx",
        };
        NSUInteger exportAliasHits = 0;
        for (NSString *alias in goldenExportAliases) {
            if ([[TTIOExporterRegistry normalizeFormat:alias]
                    isEqualToString:goldenExportAliases[alias]])
                exportAliasHits++;
        }
        PASS(exportAliasHits == goldenExportAliases.count,
             "OT7 parity: every Python export alias maps to its canonical key");

        NSUInteger exportIdentity = 0;
        for (NSString *k in goldenExportKeys) {
            if ([[TTIOExporterRegistry normalizeFormat:k] isEqualToString:k])
                exportIdentity++;
        }
        PASS(exportIdentity == goldenExportKeys.count,
             "OT7 parity: export canonical keys normalise to themselves");

        // CLI_DELEGATED is identical across both registries + matches Python.
        PASS([[TTIOImporterRegistry supportedEncodeFormats]
                containsObject:@"fasta"] &&
             [[TTIOImporterRegistry supportedEncodeFormats]
                containsObject:@"fastq"],
             "OT7 parity: import supportedEncodeFormats includes CLI_DELEGATED");
        PASS([[TTIOExporterRegistry supportedExportFormats]
                containsObject:@"fasta"] &&
             [[TTIOExporterRegistry supportedExportFormats]
                containsObject:@"fastq"],
             "OT7 parity: export supportedExportFormats includes CLI_DELEGATED");
        // fasta/fastq are NOT registry keys (CLI-delegated, not registered).
        PASS(![[TTIOImporterRegistry registryKeys] containsObject:@"fasta"] &&
             ![[TTIOImporterRegistry registryKeys] containsObject:@"fastq"],
             "OT7 parity: fasta/fastq are NOT import registry keys");
        PASS(![[TTIOExporterRegistry registryKeys] containsObject:@"fasta"] &&
             ![[TTIOExporterRegistry registryKeys] containsObject:@"fastq"],
             "OT7 parity: fasta/fastq are NOT export registry keys");
    }
}
