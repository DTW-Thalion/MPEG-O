/*
 * SPDX-License-Identifier: Apache-2.0
 */
#import "MPGOMzTabWriter.h"
#import "Dataset/MPGOIdentification.h"
#import "Dataset/MPGOQuantification.h"


@implementation MPGOMzTabWriteResult {
    NSString *_path;
    NSString *_version;
    NSUInteger _nPSM;
    NSUInteger _nPRT;
    NSUInteger _nSML;
}
- (instancetype)initWithPath:(NSString *)p
                     version:(NSString *)v
                         psm:(NSUInteger)psm
                         prt:(NSUInteger)prt
                         sml:(NSUInteger)sml
{
    self = [super init];
    if (self) {
        _path = [p copy];
        _version = [v copy];
        _nPSM = psm; _nPRT = prt; _nSML = sml;
    }
    return self;
}
- (NSString *)path { return _path; }
- (NSString *)version { return _version; }
- (NSUInteger)nPSMRows { return _nPSM; }
- (NSUInteger)nPRTRows { return _nPRT; }
- (NSUInteger)nSMLRows { return _nSML; }
@end


static NSString *EscapeTSV(NSString *v) {
    if (!v) return @"";
    NSMutableString *s = [v mutableCopy];
    [s replaceOccurrencesOfString:@"\t" withString:@" "
                           options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\r" withString:@" "
                           options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\n" withString:@" "
                           options:0 range:NSMakeRange(0, s.length)];
    return s;
}


@implementation MPGOMzTabWriter

+ (nullable MPGOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(NSArray<MPGOIdentification *> *)idents
                                quantifications:(NSArray<MPGOQuantification *> *)quants
                                         version:(NSString *)version
                                           title:(NSString *)title
                                    description:(NSString *)description
                                          error:(NSError **)error
{
    if (![version isEqualToString:@"1.0"] && ![version isEqualToString:@"2.0.0-M"]) {
        if (error) *error = [NSError errorWithDomain:@"MPGOMzTabWriter" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"unsupported mzTab version %@", version]}];
        return nil;
    }
    idents = idents ?: @[];
    quants = quants ?: @[];

    // Stable run-name → index mapping.
    NSMutableDictionary<NSString *, NSNumber *> *runIdx = [NSMutableDictionary dictionary];
    for (MPGOIdentification *ident in idents) {
        if (runIdx[ident.runName] == nil) {
            runIdx[ident.runName] = @(runIdx.count + 1);
        }
    }

    // Stable sample → assay index mapping.
    NSMutableDictionary<NSString *, NSNumber *> *sampleIdx = [NSMutableDictionary dictionary];
    for (MPGOQuantification *q in quants) {
        NSString *s = q.sampleRef ?: @"sample";
        if (sampleIdx[s] == nil) {
            sampleIdx[s] = @(sampleIdx.count + 1);
        }
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    // ── MTD ───────────────────────────────────────────────────────
    [lines addObject:[NSString stringWithFormat:@"MTD\tmzTab-version\t%@", version]];
    [lines addObject:@"MTD\tmzTab-mode\tSummary"];
    [lines addObject:@"MTD\tmzTab-type\tIdentification"];
    if ([version isEqualToString:@"1.0"]) {
        [lines addObject:@"MTD\tmzTab-ID\tmpgo-export"];
    }
    if (title.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"MTD\ttitle\t%@", EscapeTSV(title)]];
    }
    if (description.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"MTD\tdescription\t%@", EscapeTSV(description)]];
    }
    [lines addObject:@"MTD\tsoftware[1]\t[MS, MS:1000799, custom unreleased software tool, mpeg-o]"];

    // ms_run declarations — order by assigned index.
    NSArray<NSString *> *runNames = [runIdx.allKeys sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) {
            return [runIdx[a] compare:runIdx[b]];
        }];
    for (NSString *rn in runNames) {
        [lines addObject:[NSString stringWithFormat:
            @"MTD\tms_run[%@]-location\tfile://%@.mzML", runIdx[rn], rn]];
    }

    // Assay + sample declarations.
    NSArray<NSString *> *sampleNames = [sampleIdx.allKeys sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) {
            return [sampleIdx[a] compare:sampleIdx[b]];
        }];
    if (quants.count > 0) {
        for (NSString *s in sampleNames) {
            NSNumber *i = sampleIdx[s];
            [lines addObject:[NSString stringWithFormat:
                @"MTD\tassay[%@]-sample_ref\t%@", i, EscapeTSV(s)]];
            [lines addObject:[NSString stringWithFormat:
                @"MTD\tassay[%@]-quantification_reagent\t[MS, MS:1002038, unlabeled sample, %@]",
                i, EscapeTSV(s)]];
            [lines addObject:[NSString stringWithFormat:
                @"MTD\tassay[%@]-ms_run_ref\tms_run[1]", i]];
            if ([version isEqualToString:@"2.0.0-M"]) {
                [lines addObject:[NSString stringWithFormat:
                    @"MTD\tstudy_variable[%@]-description\t%@", i, EscapeTSV(s)]];
                [lines addObject:[NSString stringWithFormat:
                    @"MTD\tstudy_variable[%@]-assay_refs\tassay[%@]", i, i]];
            }
        }
    }

    [lines addObject:@""];  // blank separator

    NSUInteger nPSM = 0, nPRT = 0, nSML = 0;

    if ([version isEqualToString:@"1.0"]) {
        if (idents.count > 0) {
            [lines addObject:@"PSH\tsequence\tPSM_ID\taccession\tunique\tdatabase\tdatabase_version"
                             @"\tsearch_engine\tsearch_engine_score[1]\tmodifications"
                             @"\tretention_time\tcharge\texp_mass_to_charge\tcalc_mass_to_charge"
                             @"\tspectra_ref\tpre\tpost\tstart\tend"];
            NSUInteger psmId = 1;
            for (MPGOIdentification *ident in idents) {
                NSString *se = @"[MS, MS:1001083, mascot, ]";
                if (ident.evidenceChain.count > 0) se = ident.evidenceChain.firstObject;
                NSString *row = [NSString stringWithFormat:
                    @"PSM\t\t%lu\t%@\tnull\tnull\tnull\t%@\t%g\tnull\tnull\tnull\tnull\tnull"
                    @"\tms_run[%@]:index=%lu\tnull\tnull\tnull\tnull",
                    (unsigned long)psmId++,
                    EscapeTSV(ident.chemicalEntity),
                    EscapeTSV(se),
                    ident.confidenceScore,
                    runIdx[ident.runName],
                    (unsigned long)ident.spectrumIndex];
                [lines addObject:row];
                nPSM++;
            }
            [lines addObject:@""];
        }

        if (quants.count > 0) {
            // Group quants by chemicalEntity → {assayIdx → abundance}.
            NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *grouped =
                [NSMutableDictionary dictionary];
            for (MPGOQuantification *q in quants) {
                NSMutableDictionary *d = grouped[q.chemicalEntity];
                if (!d) { d = [NSMutableDictionary dictionary]; grouped[q.chemicalEntity] = d; }
                NSNumber *ai = sampleIdx[q.sampleRef ?: @"sample"];
                d[ai] = @(q.abundance);
            }
            NSUInteger nAssays = sampleIdx.count;

            NSMutableString *prh = [NSMutableString stringWithString:
                @"PRH\taccession\tdescription\ttaxid\tspecies\tdatabase\tdatabase_version"
                @"\tsearch_engine\tbest_search_engine_score[1]\tambiguity_members"
                @"\tmodifications\tprotein_coverage"];
            for (NSUInteger k = 1; k <= nAssays; k++) {
                [prh appendFormat:@"\tprotein_abundance_assay[%lu]", (unsigned long)k];
            }
            [lines addObject:prh];

            for (NSString *entity in grouped.allKeys) {
                NSDictionary<NSNumber *, NSNumber *> *ab = grouped[entity];
                NSMutableString *row = [NSMutableString stringWithString:@"PRT\t"];
                [row appendString:EscapeTSV(entity)];
                [row appendString:@"\t\tnull\tnull\tnull\tnull\tnull\tnull\tnull\tnull\tnull"];
                for (NSUInteger k = 1; k <= nAssays; k++) {
                    NSNumber *v = ab[@(k)];
                    [row appendFormat:@"\t%@",
                        v ? [NSString stringWithFormat:@"%g", v.doubleValue] : @"null"];
                }
                [lines addObject:row];
                nPRT++;
            }
            [lines addObject:@""];
        }
    } else {
        // Metabolomics: SMH/SML combines identification + abundance per entity.
        NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *entityQuants =
            [NSMutableDictionary dictionary];
        for (MPGOQuantification *q in quants) {
            NSMutableDictionary *d = entityQuants[q.chemicalEntity];
            if (!d) { d = [NSMutableDictionary dictionary]; entityQuants[q.chemicalEntity] = d; }
            NSNumber *ai = sampleIdx[q.sampleRef ?: @"sample"];
            d[ai] = @(q.abundance);
        }
        for (MPGOIdentification *ident in idents) {
            if (!entityQuants[ident.chemicalEntity]) {
                entityQuants[ident.chemicalEntity] = [NSMutableDictionary dictionary];
            }
        }

        if (entityQuants.count > 0) {
            NSMutableDictionary<NSString *, NSNumber *> *confidenceByEntity =
                [NSMutableDictionary dictionary];
            for (MPGOIdentification *ident in idents) {
                NSNumber *cur = confidenceByEntity[ident.chemicalEntity];
                double best = MAX(cur ? cur.doubleValue : 0.0, ident.confidenceScore);
                confidenceByEntity[ident.chemicalEntity] = @(best);
            }

            NSUInteger nSV = sampleIdx.count;
            NSMutableString *smh = [NSMutableString stringWithString:
                @"SMH\tSML_ID\tSMF_ID_REFS\tdatabase_identifier\tchemical_formula\tsmiles\tinchi"
                @"\tchemical_name\turi\ttheoretical_neutral_mass\tadduct_ions\treliability"
                @"\tbest_id_confidence_measure\tbest_id_confidence_value"];
            for (NSUInteger k = 1; k <= nSV; k++) {
                [smh appendFormat:@"\tabundance_study_variable[%lu]", (unsigned long)k];
                [smh appendFormat:@"\tabundance_variation_study_variable[%lu]", (unsigned long)k];
            }
            [lines addObject:smh];

            NSUInteger smlId = 1;
            for (NSString *entity in entityQuants.allKeys) {
                NSNumber *conf = confidenceByEntity[entity];
                double confVal = conf ? conf.doubleValue : 0.0;
                NSMutableString *row = [NSMutableString stringWithFormat:
                    @"SML\t%lu\tnull\t%@\tnull\tnull\tnull\tnull\tnull\tnull\tnull\t1"
                    @"\t[MS, MS:1001090, null, ]\t%g",
                    (unsigned long)smlId++, EscapeTSV(entity), confVal];
                NSDictionary<NSNumber *, NSNumber *> *ab = entityQuants[entity];
                for (NSUInteger k = 1; k <= nSV; k++) {
                    NSNumber *v = ab[@(k)];
                    [row appendFormat:@"\t%@",
                        v ? [NSString stringWithFormat:@"%g", v.doubleValue] : @"null"];
                    [row appendString:@"\tnull"];
                }
                [lines addObject:row];
                nSML++;
            }
            [lines addObject:@""];
        }
    }

    NSString *text = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSError *ioErr = nil;
    BOOL ok = [text writeToFile:path atomically:YES
                        encoding:NSUTF8StringEncoding error:&ioErr];
    if (!ok) { if (error) *error = ioErr; return nil; }

    return [[MPGOMzTabWriteResult alloc] initWithPath:path version:version
                                                   psm:nPSM prt:nPRT sml:nSML];
}

@end
