/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */

#import "TTIOMzTabReader.h"
#import "Dataset/TTIOFeature.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"

NSString *const TTIOMzTabReaderErrorDomain = @"TTIOMzTabReaderErrorDomain";

#pragma mark - Import value object

@implementation TTIOMzTabImport

- (instancetype)initWithVersion:(NSString *)version
                     description:(NSString *)description
                           title:(NSString *)title
                  msRunLocations:(NSDictionary *)msRunLocations
                      sampleRefs:(NSArray *)sampleRefs
                        software:(NSArray *)software
                   searchEngines:(NSArray *)searchEngines
                 identifications:(NSArray *)identifications
                 quantifications:(NSArray *)quantifications
                        features:(NSArray *)features
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
        _features = [features copy] ?: @[];
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

@implementation TTIOMzTabReader

+ (NSError *)errorWithCode:(TTIOMzTabReaderErrorCode)code message:(NSString *)message
{
    return [NSError errorWithDomain:TTIOMzTabReaderErrorDomain
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

+ (nullable TTIOMzTabImport *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) *error = [self errorWithCode:TTIOMzTabReaderErrorMissingFile
                                        message:[NSString stringWithFormat:@"mzTab file not found: %@", path]];
        return nil;
    }

    NSError *readError = nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:&readError];
    if (!text) {
        if (error) *error = [self errorWithCode:TTIOMzTabReaderErrorParseFailed
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
    NSMutableArray<TTIOIdentification *> *identifications = [NSMutableArray array];
    NSMutableArray<TTIOQuantification *> *quantifications = [NSMutableArray array];
    NSMutableArray<TTIOFeature *> *features = [NSMutableArray array];

    NSArray<NSString *> *psmHeader = nil;
    NSArray<NSString *> *prtHeader = nil;
    NSArray<NSString *> *smlHeader = nil;
    NSArray<NSString *> *pepHeader = nil;
    NSArray<NSString *> *smfHeader = nil;
    NSArray<NSString *> *smeHeader = nil;

    NSRegularExpression *msRunRegex = [NSRegularExpression regularExpressionWithPattern:@"^ms_run\\[(\\d+)\\]-location$" options:0 error:NULL];
    NSRegularExpression *assayRegex = [NSRegularExpression regularExpressionWithPattern:@"^assay\\[(\\d+)\\]-sample_ref$" options:0 error:NULL];
    NSRegularExpression *svRegex = [NSRegularExpression regularExpressionWithPattern:@"^study_variable\\[(\\d+)\\]-description$" options:0 error:NULL];
    NSRegularExpression *softwareRegex = [NSRegularExpression regularExpressionWithPattern:@"^software\\[\\d+\\](?:-setting\\[\\d+\\])?$" options:0 error:NULL];
    NSRegularExpression *seScoreRegex = [NSRegularExpression regularExpressionWithPattern:@"^psm_search_engine_score\\[\\d+\\]$" options:0 error:NULL];
    NSRegularExpression *spectraRefRegex = [NSRegularExpression regularExpressionWithPattern:@"^ms_run\\[(\\d+)\\]:(.+)$" options:0 error:NULL];
    NSRegularExpression *prtAbundanceRegex = [NSRegularExpression regularExpressionWithPattern:@"^protein_abundance_assay\\[(\\d+)\\]$" options:0 error:NULL];
    NSRegularExpression *smlAbundanceRegex = [NSRegularExpression regularExpressionWithPattern:@"^abundance_study_variable\\[(\\d+)\\]$" options:0 error:NULL];
    NSRegularExpression *psmScoreColRegex = [NSRegularExpression regularExpressionWithPattern:@"^search_engine_score\\[\\d+\\]$" options:0 error:NULL];
    NSRegularExpression *pepAssayRegex = [NSRegularExpression regularExpressionWithPattern:@"^peptide_abundance_assay\\[(\\d+)\\]$" options:0 error:NULL];
    NSRegularExpression *pepSVRegex = [NSRegularExpression regularExpressionWithPattern:@"^peptide_abundance_study_variable\\[(\\d+)\\]$" options:0 error:NULL];
    NSRegularExpression *smfAssayRegex = [NSRegularExpression regularExpressionWithPattern:@"^abundance_assay\\[(\\d+)\\]$" options:0 error:NULL];

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
            TTIOIdentification *ident = [[TTIOIdentification alloc] initWithRunName:runName
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
                TTIOQuantification *q = [[TTIOQuantification alloc] initWithChemicalEntity:accession
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

            TTIOIdentification *ident = [[TTIOIdentification alloc] initWithRunName:@"metabolomics"
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
                TTIOQuantification *q = [[TTIOQuantification alloc] initWithChemicalEntity:entity
                                                                                  sampleRef:sampleRef
                                                                                  abundance:[raw_v doubleValue]
                                                                        normalizationMethod:@""];
                [quantifications addObject:q];
            }
        } else if ([prefix isEqualToString:@"PEH"]) {
            pepHeader = cols;
        } else if ([prefix isEqualToString:@"PEP"] && pepHeader) {
            NSInteger seqIdx = [pepHeader indexOfObject:@"sequence"];
            NSInteger accIdx = [pepHeader indexOfObject:@"accession"];
            NSInteger chargeIdx = [pepHeader indexOfObject:@"charge"];
            NSInteger mzIdx = [pepHeader indexOfObject:@"mass_to_charge"];
            NSInteger rtIdx = [pepHeader indexOfObject:@"retention_time"];
            NSInteger refIdx = [pepHeader indexOfObject:@"spectra_ref"];

            NSString *sequence = (seqIdx != NSNotFound && seqIdx < (NSInteger)cols.count) ? cols[seqIdx] : @"";
            NSString *accession = (accIdx != NSNotFound && accIdx < (NSInteger)cols.count) ? cols[accIdx] : @"";
            NSString *entity = sequence.length > 0 ? sequence : accession;
            if (entity.length == 0) continue;

            NSString *ref = (refIdx != NSNotFound && refIdx < (NSInteger)cols.count) ? cols[refIdx] : @"";
            NSString *runName = @"imported";
            NSTextCheckingResult *rm = [spectraRefRegex firstMatchInString:ref options:0 range:NSMakeRange(0, ref.length)];
            if (rm) {
                NSInteger runIdxVal = [[ref substringWithRange:[rm rangeAtIndex:1]] integerValue];
                runName = [self resolveRunNameForMsRun:runIdxVal msRunLocations:msRunLocations];
            }

            NSInteger charge = 0;
            if (chargeIdx != NSNotFound && chargeIdx < (NSInteger)cols.count) {
                charge = [cols[chargeIdx] integerValue];
            }
            double mz = (mzIdx != NSNotFound && mzIdx < (NSInteger)cols.count) ? [cols[mzIdx] doubleValue] : 0.0;
            double rt = (rtIdx != NSNotFound && rtIdx < (NSInteger)cols.count) ? [cols[rtIdx] doubleValue] : 0.0;

            NSMutableDictionary<NSString *, NSNumber *> *abundances = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < pepHeader.count && i < cols.count; i++) {
                NSString *colName = pepHeader[i];
                NSString *raw_v = cols[i];
                if (raw_v.length == 0 || [raw_v isEqualToString:@"null"] || [raw_v isEqualToString:@"NA"]) continue;
                NSTextCheckingResult *am = [pepAssayRegex firstMatchInString:colName options:0 range:NSMakeRange(0, colName.length)];
                if (am) {
                    NSInteger assayIdxVal = [[colName substringWithRange:[am rangeAtIndex:1]] integerValue];
                    NSString *sampleRef = assayToSample[@(assayIdxVal)] ?: [NSString stringWithFormat:@"assay_%ld", (long)assayIdxVal];
                    abundances[sampleRef] = @([raw_v doubleValue]);
                    continue;
                }
                NSTextCheckingResult *sm = [pepSVRegex firstMatchInString:colName options:0 range:NSMakeRange(0, colName.length)];
                if (sm) {
                    NSInteger svIdxVal = [[colName substringWithRange:[sm rangeAtIndex:1]] integerValue];
                    NSString *sampleRef = studyVariables[@(svIdxVal)] ?: [NSString stringWithFormat:@"study_variable_%ld", (long)svIdxVal];
                    abundances[sampleRef] = @([raw_v doubleValue]);
                }
            }

            NSMutableArray<NSString *> *evidenceRefs = [NSMutableArray array];
            if (ref.length > 0 && ![ref isEqualToString:@"null"]) [evidenceRefs addObject:ref];

            NSString *featureId = [NSString stringWithFormat:@"pep_%lu", (unsigned long)(features.count + 1)];
            TTIOFeature *feat = [[TTIOFeature alloc] initWithFeatureId:featureId
                                                               runName:runName
                                                        chemicalEntity:entity
                                                  retentionTimeSeconds:rt
                                                       expMassToCharge:mz
                                                                charge:charge
                                                             adductIon:@""
                                                            abundances:abundances
                                                          evidenceRefs:evidenceRefs];
            [features addObject:feat];
        } else if ([prefix isEqualToString:@"SFH"]) {
            smfHeader = cols;
        } else if ([prefix isEqualToString:@"SMF"] && smfHeader) {
            NSInteger idIdx = [smfHeader indexOfObject:@"SMF_ID"];
            NSInteger smeRefsIdx = [smfHeader indexOfObject:@"SME_ID_REFS"];
            NSInteger adductIdx = [smfHeader indexOfObject:@"adduct_ion"];
            NSInteger mzIdx = [smfHeader indexOfObject:@"exp_mass_to_charge"];
            NSInteger chargeIdx = [smfHeader indexOfObject:@"charge"];
            NSInteger rtIdx = [smfHeader indexOfObject:@"retention_time_in_seconds"];

            NSString *smfId = (idIdx != NSNotFound && idIdx < (NSInteger)cols.count) ? cols[idIdx] : @"";
            if (smfId.length == 0) continue;

            NSString *smeRefsRaw = (smeRefsIdx != NSNotFound && smeRefsIdx < (NSInteger)cols.count) ? cols[smeRefsIdx] : @"";
            NSMutableArray<NSString *> *smeRefs = [NSMutableArray array];
            if (smeRefsRaw.length > 0 && ![smeRefsRaw.lowercaseString isEqualToString:@"null"]) {
                for (NSString *part in [smeRefsRaw componentsSeparatedByString:@"|"]) {
                    if (part.length > 0 && ![part.lowercaseString isEqualToString:@"null"]) {
                        [smeRefs addObject:part];
                    }
                }
            }

            NSString *adduct = (adductIdx != NSNotFound && adductIdx < (NSInteger)cols.count) ? cols[adductIdx] : @"";
            if ([adduct.lowercaseString isEqualToString:@"null"]) adduct = @"";
            double mz = (mzIdx != NSNotFound && mzIdx < (NSInteger)cols.count) ? [cols[mzIdx] doubleValue] : 0.0;
            double rt = (rtIdx != NSNotFound && rtIdx < (NSInteger)cols.count) ? [cols[rtIdx] doubleValue] : 0.0;
            NSInteger charge = 0;
            if (chargeIdx != NSNotFound && chargeIdx < (NSInteger)cols.count) {
                charge = [cols[chargeIdx] integerValue];
            }

            NSMutableDictionary<NSString *, NSNumber *> *abundances = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < smfHeader.count && i < cols.count; i++) {
                NSString *colName = smfHeader[i];
                NSString *raw_v = cols[i];
                if (raw_v.length == 0 || [raw_v isEqualToString:@"null"] || [raw_v isEqualToString:@"NA"]) continue;
                NSTextCheckingResult *am = [smfAssayRegex firstMatchInString:colName options:0 range:NSMakeRange(0, colName.length)];
                if (!am) continue;
                NSInteger assayIdxVal = [[colName substringWithRange:[am rangeAtIndex:1]] integerValue];
                NSString *sampleRef = assayToSample[@(assayIdxVal)] ?: [NSString stringWithFormat:@"assay_%ld", (long)assayIdxVal];
                abundances[sampleRef] = @([raw_v doubleValue]);
            }

            NSString *entity = smeRefs.count > 0 ? smeRefs.firstObject : smfId;
            NSString *featureId = [NSString stringWithFormat:@"smf_%@", smfId];
            TTIOFeature *feat = [[TTIOFeature alloc] initWithFeatureId:featureId
                                                               runName:@"metabolomics"
                                                        chemicalEntity:entity
                                                  retentionTimeSeconds:rt
                                                       expMassToCharge:mz
                                                                charge:charge
                                                             adductIon:adduct
                                                            abundances:abundances
                                                          evidenceRefs:smeRefs];
            [features addObject:feat];
        } else if ([prefix isEqualToString:@"SEH"]) {
            smeHeader = cols;
        } else if ([prefix isEqualToString:@"SME"] && smeHeader) {
            NSInteger idIdx = [smeHeader indexOfObject:@"SME_ID"];
            NSInteger dbIdx = [smeHeader indexOfObject:@"database_identifier"];
            NSInteger nameIdx = [smeHeader indexOfObject:@"chemical_name"];
            NSInteger formulaIdx = [smeHeader indexOfObject:@"chemical_formula"];
            NSInteger refIdx = [smeHeader indexOfObject:@"spectra_ref"];
            NSInteger rankIdx = [smeHeader indexOfObject:@"rank"];

            NSString *smeId = (idIdx != NSNotFound && idIdx < (NSInteger)cols.count) ? cols[idIdx] : @"";
            if (smeId.length == 0) continue;

            NSString *db = (dbIdx != NSNotFound && dbIdx < (NSInteger)cols.count) ? cols[dbIdx] : @"";
            NSString *chemName = (nameIdx != NSNotFound && nameIdx < (NSInteger)cols.count) ? cols[nameIdx] : @"";
            NSString *formula = (formulaIdx != NSNotFound && formulaIdx < (NSInteger)cols.count) ? cols[formulaIdx] : @"";

            NSString *entity = smeId;
            if (db.length > 0 && ![db.lowercaseString isEqualToString:@"null"]) entity = db;
            else if (chemName.length > 0 && ![chemName.lowercaseString isEqualToString:@"null"]) entity = chemName;
            else if (formula.length > 0 && ![formula.lowercaseString isEqualToString:@"null"]) entity = formula;

            NSInteger rank = 1;
            if (rankIdx != NSNotFound && rankIdx < (NSInteger)cols.count) {
                NSInteger parsed = [cols[rankIdx] integerValue];
                if (parsed > 0) rank = parsed;
            }
            double confidence = rank > 0 ? 1.0 / (double)rank : 0.0;

            NSString *runName = @"metabolomics";
            NSUInteger spectrumIndex = 0;
            NSString *ref = (refIdx != NSNotFound && refIdx < (NSInteger)cols.count) ? cols[refIdx] : @"";
            NSTextCheckingResult *rm = [spectraRefRegex firstMatchInString:ref options:0 range:NSMakeRange(0, ref.length)];
            if (rm) {
                NSInteger runIdxVal = [[ref substringWithRange:[rm rangeAtIndex:1]] integerValue];
                runName = [self resolveRunNameForMsRun:runIdxVal msRunLocations:msRunLocations];
                NSString *locator = [ref substringWithRange:[rm rangeAtIndex:2]];
                NSRange eq = [locator rangeOfString:@"="];
                if (eq.location != NSNotFound) {
                    spectrumIndex = (NSUInteger)[[locator substringFromIndex:eq.location + 1] integerValue];
                }
            }

            NSMutableArray<NSString *> *evidence = [NSMutableArray array];
            [evidence addObject:[NSString stringWithFormat:@"SME_ID=%@", smeId]];
            if (chemName.length > 0 && ![chemName isEqualToString:entity] && ![chemName.lowercaseString isEqualToString:@"null"]) {
                [evidence addObject:[NSString stringWithFormat:@"name=%@", chemName]];
            }
            if (formula.length > 0 && ![formula isEqualToString:entity] && ![formula.lowercaseString isEqualToString:@"null"]) {
                [evidence addObject:[NSString stringWithFormat:@"formula=%@", formula]];
            }

            TTIOIdentification *ident = [[TTIOIdentification alloc] initWithRunName:runName
                                                                       spectrumIndex:spectrumIndex
                                                                      chemicalEntity:entity
                                                                     confidenceScore:confidence
                                                                       evidenceChain:evidence];
            [identifications addObject:ident];

            // Back-fill features referencing this SME so their chemicalEntity
            // gets upgraded from the placeholder SME_ID.
            for (NSUInteger fi = 0; fi < features.count; fi++) {
                TTIOFeature *f = features[fi];
                if ([f.evidenceRefs containsObject:smeId] && [f.chemicalEntity isEqualToString:smeId]) {
                    TTIOFeature *upgraded = [[TTIOFeature alloc]
                        initWithFeatureId:f.featureId
                                  runName:f.runName
                           chemicalEntity:entity
                     retentionTimeSeconds:f.retentionTimeSeconds
                          expMassToCharge:f.expMassToCharge
                                   charge:f.charge
                                adductIon:f.adductIon
                               abundances:f.abundances
                             evidenceRefs:f.evidenceRefs];
                    features[fi] = upgraded;
                }
            }
        }
    }

    if (version.length == 0) {
        if (error) *error = [self errorWithCode:TTIOMzTabReaderErrorMissingVersion
                                        message:[NSString stringWithFormat:@"%@: missing MTD mzTab-version line", path]];
        return nil;
    }

    NSArray *sampleRefs = assayToSample.count > 0 ? assayToSample.allValues : studyVariables.allValues;
    return [[TTIOMzTabImport alloc] initWithVersion:version
                                         description:description
                                               title:title
                                      msRunLocations:msRunLocations
                                          sampleRefs:sampleRefs
                                            software:software
                                       searchEngines:searchEngines
                                     identifications:identifications
                                     quantifications:quantifications
                                            features:features
                                          sourcePath:path];
}

@end
