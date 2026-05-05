/*
 * TTIOMzTabWriter.m
 * TTI-O Objective-C Implementation
 *
 * Classes:       TTIOMzTabWriteResult, TTIOMzTabWriter
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Export/TTIOMzTabWriter.h
 *
 * mzTab exporter. Reverses TTIOMzTabReader: emits a tab-separated
 * mzTab file from identifications + quantifications (plus optional
 * features). Both proteomics (1.0) and metabolomics (2.0.0-M)
 * dialects are supported.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOMzTabWriter.h"
#import "Dataset/TTIOFeature.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"


@implementation TTIOMzTabWriteResult {
    NSString *_path;
    NSString *_version;
    NSUInteger _nPSM;
    NSUInteger _nPRT;
    NSUInteger _nSML;
    NSUInteger _nPEP;
    NSUInteger _nSMF;
    NSUInteger _nSME;
}
- (instancetype)initWithPath:(NSString *)p
                     version:(NSString *)v
                         psm:(NSUInteger)psm
                         prt:(NSUInteger)prt
                         sml:(NSUInteger)sml
                         pep:(NSUInteger)pep
                         smf:(NSUInteger)smf
                         sme:(NSUInteger)sme
{
    self = [super init];
    if (self) {
        _path = [p copy];
        _version = [v copy];
        _nPSM = psm; _nPRT = prt; _nSML = sml;
        _nPEP = pep; _nSMF = smf; _nSME = sme;
    }
    return self;
}
- (NSString *)path { return _path; }
- (NSString *)version { return _version; }
- (NSUInteger)nPSMRows { return _nPSM; }
- (NSUInteger)nPRTRows { return _nPRT; }
- (NSUInteger)nSMLRows { return _nSML; }
- (NSUInteger)nPEPRows { return _nPEP; }
- (NSUInteger)nSMFRows { return _nSMF; }
- (NSUInteger)nSMERows { return _nSME; }
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

/** %g-ish formatting; mirrors Python `f"{v:g}"` and Java fmt(). */
static NSString *Fmt(double v) {
    if (v == 0.0) return @"0";
    return [NSString stringWithFormat:@"%g", v];
}

static NSString *LookupSampleByIndex(NSDictionary<NSString *, NSNumber *> *sampleIdx, NSInteger k) {
    for (NSString *key in sampleIdx) {
        if ([sampleIdx[key] integerValue] == k) return key;
    }
    return nil;
}

static NSString *BuildSmeRow(NSString *smeId,
                              TTIOIdentification *ident,
                              NSDictionary<NSString *, NSNumber *> *runIdx)
{
    NSString *name = @"";
    NSString *formula = @"";
    for (NSString *e in ident.evidenceChain) {
        if ([e hasPrefix:@"name="]) name = [e substringFromIndex:[@"name=" length]];
        else if ([e hasPrefix:@"formula="]) formula = [e substringFromIndex:[@"formula=" length]];
    }
    NSInteger rank = 1;
    double score = ident.confidenceScore;
    if (score > 0) {
        double inferred = score <= 1.0 ? 1.0 / score : 1.0;
        rank = MAX(1, (NSInteger)round(inferred));
    }
    NSNumber *riNum = runIdx[ident.runName];
    NSInteger ri = riNum ? riNum.integerValue : 1;
    NSString *spectraRef = [NSString stringWithFormat:@"ms_run[%ld]:index=%lu",
                            (long)ri, (unsigned long)ident.spectrumIndex];
    return [NSString stringWithFormat:
        @"SME\t%@\tnull\t%@\t%@\tnull\tnull\t%@\tnull\tnull\tnull"
        @"\tnull\tnull\tnull\t%@\tnull\tnull\t%@\t%ld",
        EscapeTSV(smeId),
        EscapeTSV(ident.chemicalEntity),
        formula.length == 0 ? @"null" : EscapeTSV(formula),
        name.length == 0 ? @"null" : EscapeTSV(name),
        EscapeTSV(spectraRef),
        Fmt(score),
        (long)rank];
}


@implementation TTIOMzTabWriter

+ (nullable TTIOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(NSArray<TTIOIdentification *> *)idents
                                quantifications:(NSArray<TTIOQuantification *> *)quants
                                         version:(NSString *)version
                                           title:(NSString *)title
                                    description:(NSString *)description
                                          error:(NSError **)error
{
    return [self writeToPath:path
             identifications:idents
             quantifications:quants
                    features:@[]
                     version:version
                       title:title
                 description:description
                       error:error];
}

+ (nullable TTIOMzTabWriteResult *)writeToPath:(NSString *)path
                                identifications:(NSArray<TTIOIdentification *> *)idents
                                quantifications:(NSArray<TTIOQuantification *> *)quants
                                        features:(NSArray<TTIOFeature *> *)features
                                         version:(NSString *)version
                                           title:(NSString *)title
                                    description:(NSString *)description
                                          error:(NSError **)error
{
    if (![version isEqualToString:@"1.0"] && ![version isEqualToString:@"2.0.0-M"]) {
        if (error) *error = [NSError errorWithDomain:@"TTIOMzTabWriter" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"unsupported mzTab version %@", version]}];
        return nil;
    }
    idents = idents ?: @[];
    quants = quants ?: @[];
    NSArray<TTIOFeature *> *feats = features ?: @[];

    // Stable run-name → index mapping (idents + features).
    NSMutableDictionary<NSString *, NSNumber *> *runIdx = [NSMutableDictionary dictionary];
    for (TTIOIdentification *ident in idents) {
        if (runIdx[ident.runName] == nil) {
            runIdx[ident.runName] = @(runIdx.count + 1);
        }
    }
    for (TTIOFeature *f in feats) {
        if (runIdx[f.runName] == nil) {
            runIdx[f.runName] = @(runIdx.count + 1);
        }
    }

    // Stable sample → assay index mapping (quants + feature abundances).
    NSMutableDictionary<NSString *, NSNumber *> *sampleIdx = [NSMutableDictionary dictionary];
    for (TTIOQuantification *q in quants) {
        NSString *s = q.sampleRef ?: @"sample";
        if (sampleIdx[s] == nil) {
            sampleIdx[s] = @(sampleIdx.count + 1);
        }
    }
    for (TTIOFeature *f in feats) {
        for (NSString *s in f.abundances) {
            NSString *key = s.length == 0 ? @"sample" : s;
            if (sampleIdx[key] == nil) {
                sampleIdx[key] = @(sampleIdx.count + 1);
            }
        }
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    // ── MTD ───────────────────────────────────────────────────────
    [lines addObject:[NSString stringWithFormat:@"MTD\tmzTab-version\t%@", version]];
    [lines addObject:@"MTD\tmzTab-mode\tSummary"];
    [lines addObject:@"MTD\tmzTab-type\tIdentification"];
    if ([version isEqualToString:@"1.0"]) {
        [lines addObject:@"MTD\tmzTab-ID\tttio-export"];
    }
    if (title.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"MTD\ttitle\t%@", EscapeTSV(title)]];
    }
    if (description.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"MTD\tdescription\t%@", EscapeTSV(description)]];
    }
    [lines addObject:@"MTD\tsoftware[1]\t[MS, MS:1000799, custom unreleased software tool, ttio]"];

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
    if (quants.count > 0 || feats.count > 0) {
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

    NSUInteger nPSM = 0, nPRT = 0, nSML = 0, nPEP = 0, nSMF = 0, nSME = 0;

    if ([version isEqualToString:@"1.0"]) {
        // ── PSH + PSM ─────────────────────────────────────────────
        if (idents.count > 0) {
            [lines addObject:@"PSH\tsequence\tPSM_ID\taccession\tunique\tdatabase\tdatabase_version"
                             @"\tsearch_engine\tsearch_engine_score[1]\tmodifications"
                             @"\tretention_time\tcharge\texp_mass_to_charge\tcalc_mass_to_charge"
                             @"\tspectra_ref\tpre\tpost\tstart\tend"];
            NSUInteger psmId = 1;
            for (TTIOIdentification *ident in idents) {
                NSString *se = @"[MS, MS:1001083, mascot, ]";
                if (ident.evidenceChain.count > 0) se = ident.evidenceChain.firstObject;
                NSString *row = [NSString stringWithFormat:
                    @"PSM\t\t%lu\t%@\tnull\tnull\tnull\t%@\t%@\tnull\tnull\tnull\tnull\tnull"
                    @"\tms_run[%@]:index=%lu\tnull\tnull\tnull\tnull",
                    (unsigned long)psmId++,
                    EscapeTSV(ident.chemicalEntity),
                    EscapeTSV(se),
                    Fmt(ident.confidenceScore),
                    runIdx[ident.runName],
                    (unsigned long)ident.spectrumIndex];
                [lines addObject:row];
                nPSM++;
            }
            [lines addObject:@""];
        }

        // ── PRH + PRT ─────────────────────────────────────────────
        if (quants.count > 0) {
            NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *grouped =
                [NSMutableDictionary dictionary];
            for (TTIOQuantification *q in quants) {
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
                    [row appendFormat:@"\t%@", v ? Fmt(v.doubleValue) : @"null"];
                }
                [lines addObject:row];
                nPRT++;
            }
            [lines addObject:@""];
        }

        // ── PEH + PEP (peptide features, M78) ─────────────────────
        if (feats.count > 0) {
            NSUInteger nAssays = sampleIdx.count;
            NSMutableString *peh = [NSMutableString stringWithString:
                @"PEH\tsequence\taccession\tunique\tdatabase\tdatabase_version"
                @"\tsearch_engine\tbest_search_engine_score[1]\tmodifications"
                @"\tretention_time\tcharge\tmass_to_charge\turi\tspectra_ref"];
            for (NSUInteger k = 1; k <= nAssays; k++) {
                [peh appendFormat:@"\tpeptide_abundance_assay[%lu]", (unsigned long)k];
            }
            [lines addObject:peh];

            for (TTIOFeature *f in feats) {
                NSNumber *riNum = runIdx[f.runName];
                NSInteger ri = riNum ? riNum.integerValue : 1;
                NSString *ref;
                if (f.evidenceRefs.count == 0) {
                    ref = [NSString stringWithFormat:@"ms_run[%ld]:index=0", (long)ri];
                } else {
                    ref = f.evidenceRefs.firstObject;
                }
                NSMutableString *row = [NSMutableString stringWithFormat:
                    @"PEP\t%@\tnull\tnull\tnull\tnull\tnull\tnull\tnull\t%@\t%ld\t%@\tnull\t%@",
                    EscapeTSV(f.chemicalEntity),
                    Fmt(f.retentionTimeSeconds),
                    (long)f.charge,
                    Fmt(f.expMassToCharge),
                    EscapeTSV(ref)];
                for (NSUInteger k = 1; k <= nAssays; k++) {
                    NSString *sample = LookupSampleByIndex(sampleIdx, k);
                    NSNumber *v = sample ? f.abundances[sample] : nil;
                    [row appendFormat:@"\t%@", v ? Fmt(v.doubleValue) : @"null"];
                }
                [lines addObject:row];
                nPEP++;
            }
            [lines addObject:@""];
        }
    } else {
        // Metabolomics: SMH + SML.
        NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *entityQuants =
            [NSMutableDictionary dictionary];
        for (TTIOQuantification *q in quants) {
            NSMutableDictionary *d = entityQuants[q.chemicalEntity];
            if (!d) { d = [NSMutableDictionary dictionary]; entityQuants[q.chemicalEntity] = d; }
            NSNumber *ai = sampleIdx[q.sampleRef ?: @"sample"];
            d[ai] = @(q.abundance);
        }
        for (TTIOIdentification *ident in idents) {
            if (!entityQuants[ident.chemicalEntity]) {
                entityQuants[ident.chemicalEntity] = [NSMutableDictionary dictionary];
            }
        }

        if (entityQuants.count > 0) {
            NSMutableDictionary<NSString *, NSNumber *> *confidenceByEntity =
                [NSMutableDictionary dictionary];
            for (TTIOIdentification *ident in idents) {
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
                    @"\t[MS, MS:1001090, null, ]\t%@",
                    (unsigned long)smlId++, EscapeTSV(entity), Fmt(confVal)];
                NSDictionary<NSNumber *, NSNumber *> *ab = entityQuants[entity];
                for (NSUInteger k = 1; k <= nSV; k++) {
                    NSNumber *v = ab[@(k)];
                    [row appendFormat:@"\t%@", v ? Fmt(v.doubleValue) : @"null"];
                    [row appendString:@"\tnull"];
                }
                [lines addObject:row];
                nSML++;
            }
            [lines addObject:@""];
        }

        // ── SFH + SMF (small-molecule features, M78) ──────────────
        if (feats.count > 0) {
            NSUInteger nAssays = sampleIdx.count;
            NSMutableString *sfh = [NSMutableString stringWithString:
                @"SFH\tSMF_ID\tSME_ID_REFS\tSME_ID_REF_ambiguity_code\tadduct_ion"
                @"\tisotopomer\texp_mass_to_charge\tcharge"
                @"\tretention_time_in_seconds\tretention_time_in_seconds_start"
                @"\tretention_time_in_seconds_end"];
            for (NSUInteger k = 1; k <= nAssays; k++) {
                [sfh appendFormat:@"\tabundance_assay[%lu]", (unsigned long)k];
            }
            [lines addObject:sfh];

            for (TTIOFeature *f in feats) {
                NSString *smeRefs = f.evidenceRefs.count == 0
                    ? @"null" : [f.evidenceRefs componentsJoinedByString:@"|"];
                NSString *adduct = (f.adductIon.length == 0) ? @"null" : EscapeTSV(f.adductIon);
                NSMutableString *row = [NSMutableString stringWithFormat:
                    @"SMF\t%@\t%@\tnull\t%@\tnull\t%@\t%ld\t%@\tnull\tnull",
                    EscapeTSV(f.featureId),
                    EscapeTSV(smeRefs),
                    adduct,
                    Fmt(f.expMassToCharge),
                    (long)f.charge,
                    Fmt(f.retentionTimeSeconds)];
                for (NSUInteger k = 1; k <= nAssays; k++) {
                    NSString *sample = LookupSampleByIndex(sampleIdx, k);
                    NSNumber *v = sample ? f.abundances[sample] : nil;
                    [row appendFormat:@"\t%@", v ? Fmt(v.doubleValue) : @"null"];
                }
                [lines addObject:row];
                nSMF++;
            }
            [lines addObject:@""];

            // ── SEH + SME (small-molecule evidence, M78) ──────────
            NSMutableArray<TTIOIdentification *> *smeIdents = [NSMutableArray array];
            NSMutableArray<TTIOIdentification *> *plainIdents = [NSMutableArray array];
            for (TTIOIdentification *ident in idents) {
                BOOL tagged = NO;
                for (NSString *e in ident.evidenceChain) {
                    if ([e hasPrefix:@"SME_ID="]) { tagged = YES; break; }
                }
                if (tagged) [smeIdents addObject:ident];
                else [plainIdents addObject:ident];
            }
            if (smeIdents.count > 0 || plainIdents.count > 0) {
                [lines addObject:
                    @"SEH\tSME_ID\tevidence_input_id\tdatabase_identifier\tchemical_formula"
                    @"\tsmiles\tinchi\tchemical_name\turi\tderivatized_form\tadduct_ion"
                    @"\texp_mass_to_charge\tcharge\tcalc_mass_to_charge\tspectra_ref"
                    @"\tidentification_method\tms_level\tid_confidence_measure[1]\trank"];
                NSUInteger emitted = 0;
                for (TTIOIdentification *ident in smeIdents) {
                    NSString *smeId = nil;
                    for (NSString *e in ident.evidenceChain) {
                        if ([e hasPrefix:@"SME_ID="]) {
                            smeId = [e substringFromIndex:[@"SME_ID=" length]];
                            break;
                        }
                    }
                    if (smeId == nil) smeId = [NSString stringWithFormat:@"sme_%lu",
                                                (unsigned long)(emitted + 1)];
                    [lines addObject:BuildSmeRow(smeId, ident, runIdx)];
                    emitted++;
                    nSME++;
                }
                for (TTIOIdentification *ident in plainIdents) {
                    NSString *smeId = [NSString stringWithFormat:@"sme_%lu",
                                        (unsigned long)(emitted + 1)];
                    [lines addObject:BuildSmeRow(smeId, ident, runIdx)];
                    emitted++;
                    nSME++;
                }
                [lines addObject:@""];
            }
        }
    }

    NSString *text = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSError *ioErr = nil;
    BOOL ok = [text writeToFile:path atomically:YES
                        encoding:NSUTF8StringEncoding error:&ioErr];
    if (!ok) { if (error) *error = ioErr; return nil; }

    return [[TTIOMzTabWriteResult alloc] initWithPath:path version:version
                                                   psm:nPSM prt:nPRT sml:nSML
                                                   pep:nPEP smf:nSMF sme:nSME];
}

@end
