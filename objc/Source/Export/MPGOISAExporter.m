/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGOISAExporter.h"

#import "Dataset/MPGOSpectralDataset.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Spectra/MPGOChromatogram.h"

#pragma mark - TSV helpers

// ISA-Tab uses UTF-8 TSV. Cells may contain embedded tabs; we quote any
// such cell in double quotes and double any interior quotes, matching
// the conventions used by isatools' tab reader.
static NSString *isaEscape(NSString *cell)
{
    if (!cell) return @"";
    BOOL needsQuote = ([cell rangeOfString:@"\t"].location != NSNotFound ||
                       [cell rangeOfString:@"\""].location != NSNotFound ||
                       [cell rangeOfString:@"\n"].location != NSNotFound);
    if (!needsQuote) return cell;
    NSString *escaped = [cell stringByReplacingOccurrencesOfString:@"\""
                                                         withString:@"\"\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static void appendRow(NSMutableString *buf, NSArray<NSString *> *cells)
{
    NSMutableArray *escaped = [NSMutableArray arrayWithCapacity:cells.count];
    for (NSString *c in cells) [escaped addObject:isaEscape(c)];
    [buf appendString:[escaped componentsJoinedByString:@"\t"]];
    [buf appendString:@"\n"];
}

#pragma mark - Investigation file

static NSData *buildInvestigationFile(MPGOSpectralDataset *dataset,
                                      NSArray<NSString *> *runNames)
{
    NSMutableString *buf = [NSMutableString string];

    // ONTOLOGY SOURCE REFERENCE — the MS ontology is the only one we use.
    [buf appendString:@"ONTOLOGY SOURCE REFERENCE\n"];
    appendRow(buf, @[@"Term Source Name", @"MS"]);
    appendRow(buf, @[@"Term Source File", @"https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo"]);
    appendRow(buf, @[@"Term Source Version", @"4.1.0"]);
    appendRow(buf, @[@"Term Source Description", @"Proteomics Standards Initiative Mass Spectrometry Ontology"]);

    // INVESTIGATION
    [buf appendString:@"INVESTIGATION\n"];
    appendRow(buf, @[@"Investigation Identifier", dataset.isaInvestigationId ?: @""]);
    appendRow(buf, @[@"Investigation Title", dataset.title ?: @""]);
    appendRow(buf, @[@"Investigation Description", @""]);
    appendRow(buf, @[@"Investigation Submission Date", @""]);
    appendRow(buf, @[@"Investigation Public Release Date", @""]);

    // STUDY — one study per dataset (simplification: a single study
    // holding all acquisition runs as assays).
    [buf appendString:@"STUDY\n"];
    appendRow(buf, @[@"Study Identifier", dataset.isaInvestigationId ?: @""]);
    appendRow(buf, @[@"Study Title", dataset.title ?: @""]);
    appendRow(buf, @[@"Study Description", @""]);
    appendRow(buf, @[@"Study Submission Date", @""]);
    appendRow(buf, @[@"Study Public Release Date", @""]);
    appendRow(buf, @[@"Study File Name", @"s_study.txt"]);

    [buf appendString:@"STUDY ASSAYS\n"];
    NSMutableArray *measurementRow   = [NSMutableArray arrayWithObject:@"Study Assay Measurement Type"];
    NSMutableArray *technologyRow    = [NSMutableArray arrayWithObject:@"Study Assay Technology Type"];
    NSMutableArray *platformRow      = [NSMutableArray arrayWithObject:@"Study Assay Technology Platform"];
    NSMutableArray *fileNameRow      = [NSMutableArray arrayWithObject:@"Study Assay File Name"];
    for (NSString *runName in runNames) {
        MPGOAcquisitionRun *run = dataset.msRuns[runName];
        (void)run;
        [measurementRow addObject:@"metabolite profiling"];
        [technologyRow  addObject:@"mass spectrometry"];
        [platformRow    addObject:run.instrumentConfig.model ?: @""];
        [fileNameRow    addObject:[NSString stringWithFormat:@"a_assay_ms_%@.txt", runName]];
    }
    appendRow(buf, measurementRow);
    appendRow(buf, technologyRow);
    appendRow(buf, platformRow);
    appendRow(buf, fileNameRow);

    return [buf dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Study (sample) file

static NSData *buildStudyFile(MPGOSpectralDataset *dataset,
                              NSArray<NSString *> *runNames)
{
    NSMutableString *buf = [NSMutableString string];
    appendRow(buf, @[@"Source Name", @"Sample Name", @"Characteristics[organism]",
                     @"Protocol REF", @"Date"]);
    for (NSString *runName in runNames) {
        appendRow(buf, @[
            [NSString stringWithFormat:@"src_%@", runName],
            [NSString stringWithFormat:@"sample_%@", runName],
            @"",
            @"sample collection",
            @"",
        ]);
    }
    (void)dataset;
    return [buf dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Assay file

static NSData *buildAssayFile(MPGOSpectralDataset *dataset,
                              NSArray<NSString *> *runNames)
{
    NSMutableString *buf = [NSMutableString string];
    appendRow(buf, @[@"Sample Name",
                     @"Protocol REF",
                     @"Parameter Value[instrument]",
                     @"Parameter Value[ionization]",
                     @"Assay Name",
                     @"Raw Spectral Data File",
                     @"Derived Spectral Data File"]);
    for (NSString *runName in runNames) {
        MPGOAcquisitionRun *run = dataset.msRuns[runName];
        NSUInteger chromCount = run.chromatograms.count;
        NSString *derived = @"";
        if (chromCount > 0) {
            NSMutableArray *parts = [NSMutableArray array];
            for (NSUInteger i = 0; i < chromCount; i++) {
                [parts addObject:[NSString stringWithFormat:@"%@_chrom_%lu",
                                  runName, (unsigned long)i]];
            }
            derived = [parts componentsJoinedByString:@";"];
        }
        appendRow(buf, @[
            [NSString stringWithFormat:@"sample_%@", runName],
            @"mass spectrometry",
            run.instrumentConfig.model ?: @"",
            run.instrumentConfig.sourceType ?: @"",
            runName,
            [NSString stringWithFormat:@"%@.mzML", runName],
            derived,
        ]);
    }
    return [buf dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - ISA-JSON file

static NSData *buildIsaJson(MPGOSpectralDataset *dataset,
                            NSArray<NSString *> *runNames)
{
    NSMutableArray *assays = [NSMutableArray array];
    NSMutableArray *materialsSamples = [NSMutableArray array];
    NSMutableArray *materialsSources = [NSMutableArray array];

    for (NSString *runName in runNames) {
        MPGOAcquisitionRun *run = dataset.msRuns[runName];
        NSMutableArray *derivedFiles = [NSMutableArray array];
        for (NSUInteger i = 0; i < run.chromatograms.count; i++) {
            [derivedFiles addObject:@{
                @"name": [NSString stringWithFormat:@"%@_chrom_%lu",
                          runName, (unsigned long)i],
                @"type": @"Derived Spectral Data File",
            }];
        }
        [assays addObject:@{
            @"filename": [NSString stringWithFormat:@"a_assay_ms_%@.txt", runName],
            @"measurementType": @{ @"annotationValue": @"metabolite profiling" },
            @"technologyType":  @{ @"annotationValue": @"mass spectrometry" },
            @"technologyPlatform": run.instrumentConfig.model ?: @"",
            @"dataFiles": @[@{
                @"name": [NSString stringWithFormat:@"%@.mzML", runName],
                @"type": @"Raw Spectral Data File",
            }],
            @"derivedFiles": derivedFiles,
        }];
        [materialsSamples addObject:@{
            @"@id": [NSString stringWithFormat:@"#sample/%@", runName],
            @"name": [NSString stringWithFormat:@"sample_%@", runName],
        }];
        [materialsSources addObject:@{
            @"@id": [NSString stringWithFormat:@"#source/%@", runName],
            @"name": [NSString stringWithFormat:@"src_%@", runName],
        }];
    }

    NSDictionary *study = @{
        @"identifier": dataset.isaInvestigationId ?: @"",
        @"title":      dataset.title ?: @"",
        @"filename":   @"s_study.txt",
        @"materials":  @{
            @"sources": materialsSources,
            @"samples": materialsSamples,
        },
        @"assays": assays,
    };

    NSDictionary *investigation = @{
        @"identifier": dataset.isaInvestigationId ?: @"",
        @"title":      dataset.title ?: @"",
        @"ontologySourceReferences": @[@{
            @"name": @"MS",
            @"file": @"https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo",
            @"version": @"4.1.0",
            @"description": @"Proteomics Standards Initiative Mass Spectrometry Ontology",
        }],
        @"studies": @[study],
    };

    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:investigation
                                                    options:(NSJSONWritingPrettyPrinted |
                                                             NSJSONWritingSortedKeys)
                                                      error:&err];
    if (!data) return [NSData data];
    // Append trailing newline for POSIX friendliness + byte-parity with Python.
    NSMutableData *out = [data mutableCopy];
    [out appendBytes:"\n" length:1];
    return out;
}

#pragma mark - Public API

@implementation MPGOISAExporter

+ (NSDictionary<NSString *, NSData *> *)bundleForDataset:(MPGOSpectralDataset *)dataset
                                                    error:(NSError **)error
{
    if (!dataset) {
        if (error) *error = [NSError errorWithDomain:@"MPGOISAExporter"
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                          @"nil dataset"}];
        return nil;
    }

    NSArray<NSString *> *runNames =
        [[dataset.msRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];

    NSMutableDictionary<NSString *, NSData *> *out = [NSMutableDictionary dictionary];
    out[@"i_investigation.txt"] = buildInvestigationFile(dataset, runNames);
    out[@"s_study.txt"]         = buildStudyFile(dataset, runNames);
    for (NSString *runName in runNames) {
        NSString *filename = [NSString stringWithFormat:@"a_assay_ms_%@.txt", runName];
        out[filename] = buildAssayFile(dataset, @[runName]);
    }
    out[@"investigation.json"]  = buildIsaJson(dataset, runNames);
    return [out copy];
}

+ (BOOL)writeBundleForDataset:(MPGOSpectralDataset *)dataset
                  toDirectory:(NSString *)directoryPath
                        error:(NSError **)error
{
    NSDictionary *bundle = [self bundleForDataset:dataset error:error];
    if (!bundle) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:directoryPath]) {
        if (![fm createDirectoryAtPath:directoryPath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:error]) {
            return NO;
        }
    }
    for (NSString *name in bundle) {
        NSString *path = [directoryPath stringByAppendingPathComponent:name];
        if (![bundle[name] writeToFile:path options:NSDataWritingAtomic error:error]) {
            return NO;
        }
    }
    return YES;
}

@end
