/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGOMzTabReader.h"
#import "Dataset/MPGOIdentification.h"
#import "Dataset/MPGOQuantification.h"

NSString *const MPGOMzTabReaderErrorDomain = @"MPGOMzTabReaderErrorDomain";

#pragma mark - Import value object

@implementation MPGOMzTabImport

- (instancetype)initWithVersion:(NSString *)version
                     description:(NSString *)description
                           title:(NSString *)title
                  msRunLocations:(NSDictionary *)msRunLocations
                      sampleRefs:(NSArray *)sampleRefs
                        software:(NSArray *)software
                   searchEngines:(NSArray *)searchEngines
                 identifications:(NSArray *)identifications
                 quantifications:(NSArray *)quantifications
                      sourcePath:(NSString *)sourcePath
{
    if ((self = [super init])) {
        _version = [version copy] ?: @"";
        _importDescription = [description copy] ?: @"";
        _title = [title copy] ?: @"";
        _msRunLocations = [msRunLocations copy] ?: @{};
        _sampleRefs = [sampleRefs copy] ?: @[];
        _software = [software copy] ?: @[];
        _searchEngines = [searchEngines copy] ?: @[];
        _identifications = [identifications copy] ?: @[];
        _quantifications = [quantifications copy] ?: @[];
        _sourcePath = [sourcePath copy] ?: @"";
    }
    return self;
}

- (BOOL)isMetabolomics
{
    return [_version hasSuffix:@"-M"];
}

@end

#pragma mark - Reader

@implementation MPGOMzTabReader

+ (NSError *)errorWithCode:(MPGOMzTabReaderErrorCode)code message:(NSString *)message
{
    return [NSError errorWithDomain:MPGOMzTabReaderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (NSString *)resolveRunNameForMsRun:(NSInteger)msRunIndex
                       msRunLocations:(NSDictionary<NSNumber *, NSString *> *)locations
{
    NSString *location = locations[@(msRunIndex)];
    if (location.length == 0) return [NSString stringWithFormat:@"run_%ld", (long)msRunIndex];
    NSArray *parts = [location componentsSeparatedByString:@"/"];
    NSString *name = [parts.lastObject copy];
    NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound) name = [name substringToIndex:dot.location];
    return name.length > 0 ? name : [NSString stringWithFormat:@"run_%ld", (long)msRunIndex];
}

+ (nullable MPGOMzTabImport *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) *error = [self errorWithCode:MPGOMzTabReaderErrorMissingFile
                                        message:[NSString stringWithFormat:@"mzTab file not found: %@", path]];
        return nil;
    }

    NSError *readError = nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:&readError];
    if (!text) {
        if (error) *error = [self errorWithCode:MPGOMzTabReaderErrorParseFailed
                                        message:[NSString stringWithFormat:@"cannot read %@: %@", path, readError.localizedDescription]];
        return nil;
    }

    NSString *version = @"";
    NSString *description = @"";
    NSString *title = @"";
    NSMutableDictionary<NSNumber *, NSString *> *msRunLocations = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSString *> *assayToSample = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSString *> *studyVariables = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *software = [NSMutableArray array];
    NSMutableArray<NSString *> *searchEngines = [NSMutableArray array];
    NSMutableArray<MPGOIdentification *> *identifications = [NSMutableArray array];
    NSMutableArray<MPGOQuantification *> *quantifications = [NSMutableArray array];

    NSArray<NSString *> *psmHeader = nil;
    NSArray<NSString *> *prtHeader = nil;
    NSArray<NSString *> *smlHeader = nil;

    NSRegularExpression *msRunRegex = [NSRegularExpression regularExpressionWithPattern:@"^ms_run\\[(\\d+)\\]-location$" options:0 error:NULL];
    NSRegularExpression *assayRegex = [NSRegularExpression regularExpressionWithPattern:@"^assay\\[(\\d+)\\]-sample_ref$" options:0 error:NULL];
    NSRegularExpression *svRegex = [NSRegularExpression regularExpressionWithPattern:@"^study_variable\\[(\\d+)\\]-description$" options:0 error:NULL];
    NSRegularExpression *softwareRegex = [NSRegularExpression regularExpressionWithPattern:@"^software\\[\\d+\\](?:-setting\\[\\d+\\])?$" options:0 error:NULL];
    NSRegularExpression *seScoreRegex = [NSRegularExpression regularExpressionWithPattern:@"^psm_search_engine_score\\[\\d+\\]$" options:0 error:NULL];
    NSRegularExpression *spectraRefRegex = [NSRegularExpression regularExpressionWithPattern:@"^ms_run\\[(\\d+)\\]:(.+)$" options:0 error:NULL];
    NSRegularExpression *prtAbundanceRegex = [NSRegularExpression regularExpressionWithPattern:@"^protein_abundance_assay\\[(\\d+)\\]$" options:0 error:NULL];
    NSRegularExpression *smlAbundanceRegex = [NSRegularExpression regularExpressionWithPattern:@"^abundance_study_variable\\[(\\d+)\\]$" options:0 error:NULL];
    NSRegularExpression *psmScoreColRegex = [NSRegularExpression regularExpressionWithPattern:@"^search_engine_score\\[\\d+\\]$" options:0 error:NULL];

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSArray<NSString *> *cols = [line componentsSeparatedByString:@"\t"];
        NSString *prefix = cols.firstObject;
        if ([prefix isEqualToString:@"COM"]) continue;
        if ([prefix isEqualToString:@"MTD"]) {
            if (cols.count < 3) continue;
            NSString *key = cols[1];
            NSString *value = [[cols subarrayWithRange:NSMakeRange(2, cols.count - 2)] componentsJoinedByString:@"\t"];
            if ([key isEqualToString:@"mzTab-version"]) {
                version = value;
            } else if ([key isEqualToString:@"description"] || [key isEqualToString:@"mzTab-description"]) {
                description = value;
            } else if ([key isEqualToString:@"mzTab-ID"] || [key isEqualToString:@"title"]) {
                title = value;
            } else {
                NSTextCheckingResult *m = [msRunRegex firstMatchInString:key options:0 range:NSMakeRange(0, key.length)];
                if (m) { msRunLocations[@([[key substringWithRange:[m rangeAtIndex:1]] integerValue])] = value; continue; }
                m = [assayRegex firstMatchInString:key options:0 range:NSMakeRange(0, key.length)];
                if (m) { assayToSample[@([[key substringWithRange:[m rangeAtIndex:1]] integerValue])] = value; continue; }
                m = [svRegex firstMatchInString:key options:0 range:NSMakeRange(0, key.length)];
                if (m) { studyVariables[@([[key substringWithRange:[m rangeAtIndex:1]] integerValue])] = value; continue; }
                if ([softwareRegex firstMatchInString:key options:0 range:NSMakeRange(0, key.length)]) {
                    [software addObject:value]; continue;
                }
                if ([seScoreRegex firstMatchInString:key options:0 range:NSMakeRange(0, key.length)]) {
                    [searchEngines addObject:value]; continue;
                }
            }
        } else if ([prefix isEqualToString:@"PSH"]) {
            psmHeader = cols;
        } else if ([prefix isEqualToString:@"PSM"] && psmHeader) {
            // Build column index map.
            NSInteger accIdx = [psmHeader indexOfObject:@"accession"];
            NSInteger seqIdx = [psmHeader indexOfObject:@"sequence"];
            NSInteger seIdx = [psmHeader indexOfObject:@"search_engine"];
            NSInteger psmIdIdx = [psmHeader indexOfObject:@"PSM_ID"];
            NSInteger refIdx = [psmHeader indexOfObject:@"spectra_ref"];
            NSString *accession = (accIdx != NSNotFound && accIdx < (NSInteger)cols.count) ? cols[accIdx] : @"";
            if (accession.length == 0 || [accession isEqualToString:@"null"]) {
                if (seqIdx != NSNotFound && seqIdx < (NSInteger)cols.count) accession = cols[seqIdx];
            }
            if (accession.length == 0) continue;

            NSString *runName = @"imported";
            NSUInteger spectrumIndex = 0;
            if (refIdx != NSNotFound && refIdx < (NSInteger)cols.count) {
                NSString *ref = cols[refIdx];
                NSTextCheckingResult *m = [spectraRefRegex firstMatchInString:ref options:0 range:NSMakeRange(0, ref.length)];
                if (m) {
                    NSInteger runIdx = [[ref substringWithRange:[m rangeAtIndex:1]] integerValue];
                    runName = [self resolveRunNameForMsRun:runIdx msRunLocations:msRunLocations];
                    NSString *locator = [ref substringWithRange:[m rangeAtIndex:2]];
                    NSRange eq = [locator rangeOfString:@"="];
                    if (eq.location != NSNotFound) {
                        spectrumIndex = (NSUInteger)[[locator substringFromIndex:eq.location + 1] integerValue];
                    }
                }
            }

            double bestScore = 0.0;
            for (NSUInteger i = 0; i < psmHeader.count && i < cols.count; i++) {
                NSString *colName = psmHeader[i];
                if ([psmScoreColRegex firstMatchInString:colName options:0 range:NSMakeRange(0, colName.length)]) {
                    double v = [cols[i] doubleValue];
                    if (v > bestScore) bestScore = v;
                }
            }

            NSMutableArray<NSString *> *evidence = [NSMutableArray array];
            if (seIdx != NSNotFound && seIdx < (NSInteger)cols.count && cols[seIdx].length) {
                [evidence addObject:cols[seIdx]];
            }
            if (psmIdIdx != NSNotFound && psmIdIdx < (NSInteger)cols.count && cols[psmIdIdx].length) {
                [evidence addObject:[NSString stringWithFormat:@"PSM_ID=%@", cols[psmIdIdx]]];
            }
            MPGOIdentification *ident = [[MPGOIdentification alloc] initWithRunName:runName
                                                                       spectrumIndex:spectrumIndex
                                                                      chemicalEntity:accession
                                                                     confidenceScore:bestScore
                                                                       evidenceChain:evidence];
            [identifications addObject:ident];
        } else if ([prefix isEqualToString:@"PRH"]) {
            prtHeader = cols;
        } else if ([prefix isEqualToString:@"PRT"] && prtHeader) {
            NSInteger accIdx = [prtHeader indexOfObject:@"accession"];
            NSString *accession = (accIdx != NSNotFound && accIdx < (NSInteger)cols.count) ? cols[accIdx] : @"";
            if (accession.length == 0) continue;
            for (NSUInteger i = 0; i < prtHeader.count && i < cols.count; i++) {
                NSString *colName = prtHeader[i];
                NSTextCheckingResult *m = [prtAbundanceRegex firstMatchInString:colName options:0 range:NSMakeRange(0, colName.length)];
                if (!m) continue;
                NSString *raw_v = cols[i];
                if (raw_v.length == 0 || [raw_v isEqualToString:@"null"] || [raw_v isEqualToString:@"NA"]) continue;
                NSInteger assayIdx = [[colName substringWithRange:[m rangeAtIndex:1]] integerValue];
                NSString *sampleRef = assayToSample[@(assayIdx)] ?: [NSString stringWithFormat:@"assay_%ld", (long)assayIdx];
                MPGOQuantification *q = [[MPGOQuantification alloc] initWithChemicalEntity:accession
                                                                                  sampleRef:sampleRef
                                                                                  abundance:[raw_v doubleValue]
                                                                        normalizationMethod:@""];
                [quantifications addObject:q];
            }
        } else if ([prefix isEqualToString:@"SMH"]) {
            smlHeader = cols;
        } else if ([prefix isEqualToString:@"SML"] && smlHeader) {
            NSInteger dbIdIdx = [smlHeader indexOfObject:@"database_identifier"];
            NSInteger nameIdx = [smlHeader indexOfObject:@"chemical_name"];
            NSInteger formulaIdx = [smlHeader indexOfObject:@"chemical_formula"];
            NSInteger bestConfIdx = [smlHeader indexOfObject:@"best_id_confidence_value"];
            NSString *entity = @"";
            if (dbIdIdx != NSNotFound && dbIdIdx < (NSInteger)cols.count) entity = cols[dbIdIdx];
            NSString *name = (nameIdx != NSNotFound && nameIdx < (NSInteger)cols.count) ? cols[nameIdx] : @"";
            NSString *formula = (formulaIdx != NSNotFound && formulaIdx < (NSInteger)cols.count) ? cols[formulaIdx] : @"";
            if (entity.length == 0) entity = name.length ? name : formula;
            if (entity.length == 0) continue;
            double best = (bestConfIdx != NSNotFound && bestConfIdx < (NSInteger)cols.count) ? [cols[bestConfIdx] doubleValue] : 0.0;
            NSMutableArray<NSString *> *evidence = [NSMutableArray array];
            if (name.length && ![name isEqualToString:entity]) [evidence addObject:[NSString stringWithFormat:@"name=%@", name]];
            if (formula.length && ![formula isEqualToString:entity]) [evidence addObject:[NSString stringWithFormat:@"formula=%@", formula]];

            MPGOIdentification *ident = [[MPGOIdentification alloc] initWithRunName:@"metabolomics"
                                                                       spectrumIndex:0
                                                                      chemicalEntity:entity
                                                                     confidenceScore:best
                                                                       evidenceChain:evidence];
            [identifications addObject:ident];

            for (NSUInteger i = 0; i < smlHeader.count && i < cols.count; i++) {
                NSString *colName = smlHeader[i];
                NSTextCheckingResult *m = [smlAbundanceRegex firstMatchInString:colName options:0 range:NSMakeRange(0, colName.length)];
                if (!m) continue;
                NSString *raw_v = cols[i];
                if (raw_v.length == 0 || [raw_v isEqualToString:@"null"]) continue;
                NSInteger svIdx = [[colName substringWithRange:[m rangeAtIndex:1]] integerValue];
                NSString *sampleRef = studyVariables[@(svIdx)] ?: [NSString stringWithFormat:@"study_variable_%ld", (long)svIdx];
                MPGOQuantification *q = [[MPGOQuantification alloc] initWithChemicalEntity:entity
                                                                                  sampleRef:sampleRef
                                                                                  abundance:[raw_v doubleValue]
                                                                        normalizationMethod:@""];
                [quantifications addObject:q];
            }
        }
    }

    if (version.length == 0) {
        if (error) *error = [self errorWithCode:MPGOMzTabReaderErrorMissingVersion
                                        message:[NSString stringWithFormat:@"%@: missing MTD mzTab-version line", path]];
        return nil;
    }

    NSArray *sampleRefs = assayToSample.count > 0 ? assayToSample.allValues : studyVariables.allValues;
    return [[MPGOMzTabImport alloc] initWithVersion:version
                                         description:description
                                               title:title
                                      msRunLocations:msRunLocations
                                          sampleRefs:sampleRefs
                                            software:software
                                       searchEngines:searchEngines
                                     identifications:identifications
                                     quantifications:quantifications
                                          sourcePath:path];
}

@end
