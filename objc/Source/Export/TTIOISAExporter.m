/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "TTIOISAExporter.h"

#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOChromatogram.h"

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

static NSData *buildInvestigationFile(TTIOSpectralDataset *dataset,
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

    // ISA-Tab 1.0 requires every investigation-file section header
    // to be present, even when data rows are empty. isatools halts
    // validation at the first missing required section.
    [buf appendString:@"INVESTIGATION PUBLICATIONS\n"];
    appendRow(buf, @[@"Investigation PubMed ID"]);
    appendRow(buf, @[@"Investigation Publication DOI"]);
    appendRow(buf, @[@"Investigation Publication Author List"]);
    appendRow(buf, @[@"Investigation Publication Title"]);
    appendRow(buf, @[@"Investigation Publication Status"]);
    appendRow(buf, @[@"Investigation Publication Status Term Accession Number"]);
    appendRow(buf, @[@"Investigation Publication Status Term Source REF"]);

    [buf appendString:@"INVESTIGATION CONTACTS\n"];
    appendRow(buf, @[@"Investigation Person Last Name"]);
    appendRow(buf, @[@"Investigation Person First Name"]);
    appendRow(buf, @[@"Investigation Person Mid Initials"]);
    appendRow(buf, @[@"Investigation Person Email"]);
    appendRow(buf, @[@"Investigation Person Phone"]);
    appendRow(buf, @[@"Investigation Person Fax"]);
    appendRow(buf, @[@"Investigation Person Address"]);
    appendRow(buf, @[@"Investigation Person Affiliation"]);
    appendRow(buf, @[@"Investigation Person Roles"]);
    appendRow(buf, @[@"Investigation Person Roles Term Accession Number"]);
    appendRow(buf, @[@"Investigation Person Roles Term Source REF"]);

    // STUDY
    NSString *studyDesc = dataset.title ?: (dataset.isaInvestigationId ?: @"TTI-O exported study");
    [buf appendString:@"STUDY\n"];
    appendRow(buf, @[@"Study Identifier", dataset.isaInvestigationId ?: @""]);
    appendRow(buf, @[@"Study Title", dataset.title ?: @""]);
    appendRow(buf, @[@"Study Description", studyDesc]);
    appendRow(buf, @[@"Study Submission Date", @""]);
    appendRow(buf, @[@"Study Public Release Date", @""]);
    appendRow(buf, @[@"Study File Name", @"s_study.txt"]);

    [buf appendString:@"STUDY DESIGN DESCRIPTORS\n"];
    appendRow(buf, @[@"Study Design Type"]);
    appendRow(buf, @[@"Study Design Type Term Accession Number"]);
    appendRow(buf, @[@"Study Design Type Term Source REF"]);

    [buf appendString:@"STUDY PUBLICATIONS\n"];
    appendRow(buf, @[@"Study PubMed ID"]);
    appendRow(buf, @[@"Study Publication DOI"]);
    appendRow(buf, @[@"Study Publication Author List"]);
    appendRow(buf, @[@"Study Publication Title"]);
    appendRow(buf, @[@"Study Publication Status"]);
    appendRow(buf, @[@"Study Publication Status Term Accession Number"]);
    appendRow(buf, @[@"Study Publication Status Term Source REF"]);

    [buf appendString:@"STUDY FACTORS\n"];
    appendRow(buf, @[@"Study Factor Name"]);
    appendRow(buf, @[@"Study Factor Type"]);
    appendRow(buf, @[@"Study Factor Type Term Accession Number"]);
    appendRow(buf, @[@"Study Factor Type Term Source REF"]);

    [buf appendString:@"STUDY ASSAYS\n"];
    NSMutableArray *measurementRow   = [NSMutableArray arrayWithObject:@"Study Assay Measurement Type"];
    NSMutableArray *measurementAcc   = [NSMutableArray arrayWithObject:@"Study Assay Measurement Type Term Accession Number"];
    NSMutableArray *measurementRef   = [NSMutableArray arrayWithObject:@"Study Assay Measurement Type Term Source REF"];
    NSMutableArray *technologyRow    = [NSMutableArray arrayWithObject:@"Study Assay Technology Type"];
    NSMutableArray *technologyAcc    = [NSMutableArray arrayWithObject:@"Study Assay Technology Type Term Accession Number"];
    NSMutableArray *technologyRef    = [NSMutableArray arrayWithObject:@"Study Assay Technology Type Term Source REF"];
    NSMutableArray *platformRow      = [NSMutableArray arrayWithObject:@"Study Assay Technology Platform"];
    NSMutableArray *fileNameRow      = [NSMutableArray arrayWithObject:@"Study Assay File Name"];
    for (NSString *runName in runNames) {
        TTIOAcquisitionRun *run = dataset.msRuns[runName];
        [measurementRow addObject:@"metabolite profiling"];
        [measurementAcc addObject:@""];
        [measurementRef addObject:@""];
        [technologyRow  addObject:@"mass spectrometry"];
        [technologyAcc  addObject:@""];
        [technologyRef  addObject:@""];
        [platformRow    addObject:run.instrumentConfig.model ?: @""];
        [fileNameRow    addObject:[NSString stringWithFormat:@"a_assay_ms_%@.txt", runName]];
    }
    appendRow(buf, measurementRow);
    appendRow(buf, measurementAcc);
    appendRow(buf, measurementRef);
    appendRow(buf, technologyRow);
    appendRow(buf, technologyAcc);
    appendRow(buf, technologyRef);
    appendRow(buf, platformRow);
    appendRow(buf, fileNameRow);

    // STUDY PROTOCOLS — must declare every Protocol REF used in the
    // study + assay files ("sample collection" and "mass spectrometry").
    [buf appendString:@"STUDY PROTOCOLS\n"];
    appendRow(buf, @[@"Study Protocol Name", @"sample collection", @"mass spectrometry"]);
    appendRow(buf, @[@"Study Protocol Type", @"sample collection", @"mass spectrometry"]);
    appendRow(buf, @[@"Study Protocol Type Term Accession Number", @"", @""]);
    appendRow(buf, @[@"Study Protocol Type Term Source REF", @"", @""]);
    appendRow(buf, @[@"Study Protocol Description", @"", @""]);
    appendRow(buf, @[@"Study Protocol URI", @"", @""]);
    appendRow(buf, @[@"Study Protocol Version", @"", @""]);
    appendRow(buf, @[@"Study Protocol Parameters Name", @"", @""]);
    appendRow(buf, @[@"Study Protocol Parameters Name Term Accession Number", @"", @""]);
    appendRow(buf, @[@"Study Protocol Parameters Name Term Source REF", @"", @""]);
    appendRow(buf, @[@"Study Protocol Components Name", @"", @""]);
    appendRow(buf, @[@"Study Protocol Components Type", @"", @""]);
    appendRow(buf, @[@"Study Protocol Components Type Term Accession Number", @"", @""]);
    appendRow(buf, @[@"Study Protocol Components Type Term Source REF", @"", @""]);

    [buf appendString:@"STUDY CONTACTS\n"];
    appendRow(buf, @[@"Study Person Last Name"]);
    appendRow(buf, @[@"Study Person First Name"]);
    appendRow(buf, @[@"Study Person Mid Initials"]);
    appendRow(buf, @[@"Study Person Email"]);
    appendRow(buf, @[@"Study Person Phone"]);
    appendRow(buf, @[@"Study Person Fax"]);
    appendRow(buf, @[@"Study Person Address"]);
    appendRow(buf, @[@"Study Person Affiliation"]);
    appendRow(buf, @[@"Study Person Roles"]);
    appendRow(buf, @[@"Study Person Roles Term Accession Number"]);
    appendRow(buf, @[@"Study Person Roles Term Source REF"]);

    return [buf dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Study (sample) file

static NSData *buildStudyFile(TTIOSpectralDataset *dataset,
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

static NSData *buildAssayFile(TTIOSpectralDataset *dataset,
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
        TTIOAcquisitionRun *run = dataset.msRuns[runName];
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

static NSData *buildIsaJson(TTIOSpectralDataset *dataset,
                            NSArray<NSString *> *runNames)
{
    NSMutableArray *assays = [NSMutableArray array];
    NSMutableArray *materialsSamples = [NSMutableArray array];
    NSMutableArray *materialsSources = [NSMutableArray array];

    for (NSString *runName in runNames) {
        TTIOAcquisitionRun *run = dataset.msRuns[runName];
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

@implementation TTIOISAExporter

+ (NSDictionary<NSString *, NSData *> *)bundleForDataset:(TTIOSpectralDataset *)dataset
                                                    error:(NSError **)error
{
    if (!dataset) {
        if (error) *error = [NSError errorWithDomain:@"TTIOISAExporter"
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

+ (BOOL)writeBundleForDataset:(TTIOSpectralDataset *)dataset
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
